# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

require_relative "errors"
require_relative "prompt"
require_relative "validator"
require_relative "repository"

module AgentsFyi
  module Consultant
    # **One task at a time, with a heartbeat and a record.** The loop asks the service what to do,
    # reads the question, gives the model a bounded prompt, validates the answer, posts it and
    # completes or fails the lease. It never accepts, never applies an effect and never keeps a
    # local ledger: the service is the truth, and the lease is what stops two consultants spending
    # twice on one question.
    class Loop
      HEARTBEAT_SECONDS = 600
      LEASE_SECONDS = 900
      DEFAULT_INTERVAL = 300

      def initialize(client:, runner:, config:, out: $stdout, err: $stderr, clock: Time)
        @client = client
        @runner = runner
        @config = config
        @out = out
        @err = err
        @clock = clock
      end

      # `cycles` is the outer poll; `max_tasks` is the work bound for a bounded run. Both are
      # checked after every task, so neither a provider error nor a pause can skip the bound.
      def run(cycles: 1, max_tasks: nil)
        done = 0
        cycles.to_i.times do |cycle|
          # A loop that is alive but has no work still has to say so: the container's health
          # check reads this file, and "no task due" is a healthy consultant, not a dead one.
          write_heartbeat
          control = read_control
          if control["paused"]
            log("paused: #{control['reason'] || 'the agent control is paused'}")
            sleep_interval
            next
          end

          tasks = claim_tasks
          if tasks.empty?
            log("no task due (cycle #{cycle + 1}/#{cycles})")
            sleep_interval
            next
          end

          tasks.each do |task|
            process(task)
            done += 1
            break if max_tasks && done >= max_tasks.to_i
          end
          break if max_tasks && done >= max_tasks.to_i
          sleep_interval
        end
        done
      end

      # One task, as a step a test can drive without a loop. The result is the id the service stored,
      # or nil when the task was failed.
      def process(task)
        task_id = task["id"].to_s
        lease = task["lease_token"].to_s
        question = task["question"].is_a?(Hash) ? task["question"] : {}
        mode = task["kind"].to_s
        heartbeat(task_id, lease)
        repository, repository_problem = repository_for(task, mode, question)
        if repository_problem && %w[profile scan repair].include?(mode)
          # A repository this container cannot read is a fact about access, not a model failure:
          # a person decides whether to grant it or fill the profile by hand.
          fail_task(task_id, lease, "the repository could not be read: #{repository_problem}",
            retryable: false)
          return nil
        end
        run_detail = run_for(task, question)
        prompt = if mode == "review"
          Prompt.build_review(task, question: question, run: run_detail,
            repository: repository.is_a?(Hash) ? repository : nil)
        else
          Prompt.build(task, mode: mode,
            repository: repository.is_a?(Hash) ? repository : nil, run: run_detail)
        end
        model = mode == "review" ? review_model_for(task) : model_for(task)
        started = @clock.now
        text, error, usage = if mode == "review"
          @runner.run(prompt, model: model, mode: mode, agent: @config.review_agent)
        else
          @runner.run(prompt, model: model, mode: mode)
        end
        seconds = (@clock.now - started).to_i
        tokens_in = usage.is_a?(Hash) ? usage["tokens_in"].to_i : 0
        tokens_out = usage.is_a?(Hash) ? usage["tokens_out"].to_i : 0

        if error
          fail_task(task_id, lease, error.message, retryable: error.retryable?,
            model: model, usage: usage, seconds: seconds)
          return nil
        end

        proposal, problem = case mode
        when "profile" then Validator.read_profile(text)
        when "scan" then Validator.read_scan(text)
        when "review" then Validator.read_review(text)
        else Validator.read(text, mode: mode)
        end
        if problem
          debug("validator refused #{task_id}: #{problem}", text)
          record(task, prompt: prompt, text: text, error: problem, model: model, usage: usage)
          fail_task(task_id, lease, problem, retryable: false,
            model: model, usage: usage, seconds: seconds)
          return nil
        end

        posted = case mode
        when "profile" then post_profile(task, proposal, model: model)
        when "scan" then post_scan(proposal)
        when "review" then post_review(task, question, proposal, model: model,
          seconds: seconds, tokens_in: tokens_in, tokens_out: tokens_out)
        else post_answer(task, question, proposal, model: model)
        end
        if posted.is_a?(String)
          debug("service refused #{task_id}: #{posted}", text)
          record(task, prompt: prompt, text: text, error: posted, model: model, usage: usage)
          fail_task(task_id, lease, posted, retryable: false,
            model: model, usage: usage, seconds: seconds)
          return nil
        end

        # **A review POST completes its own task.** The endpoint stores the verdict, completes the
        # lease and runs the gate in one request; a second `complete` would be a completion of a
        # task that is already `completed`.
        unless mode == "review"
          @client.complete(task_id, lease, result: posted, model: model,
            tokens_in: tokens_in, tokens_out: tokens_out, calls: 1, seconds: seconds)
        end
        record(task, prompt: prompt, text: text, result: posted, model: model, usage: usage)
        log("task #{task_id} (#{mode}) completed: #{posted.inspect}")
        posted.values.first
      rescue Error => e
        fail_task(task_id, lease, e.message, retryable: e.retryable?,
          model: defined?(model) ? model : nil, usage: defined?(usage) ? usage : nil,
          seconds: defined?(seconds) ? seconds : 0) if task_id && lease
        log("task #{task_id} failed: #{e.message}")
        nil
      end

      private

      # A block names the run that produced it; the patch is what a repair is about. A read that
      # fails is not fatal — the model can still answer from the question — but it is logged.
      def run_for(task, question = {})
        id = task["run_id"].to_s
        # A repair question filed before the walker sent the run at the top level still names it
        # in its evidence; the patch is the same either way.
        id = question.dig("evidence", "run_id").to_s if id.empty? && question.is_a?(Hash)
        return nil if id.empty?

        @client.run(id)
      rescue Error => e
        log("run #{id} could not be read: #{e.message}")
        nil
      end

      # The mirror is cache, not evidence: a clone failure is reported as `:unreadable` and the
      # caller decides whether the task can proceed from the question's own evidence.
      def repository_for(task, mode, question)
        source = Repository.new(config: @config, task: task, out: @out, err: @err)
        return [nil, nil] unless source.available?

        snapshot, problem = source.snapshot(mode: mode, question: question)
        if problem
          log("repository unavailable for #{task['id']}: #{problem}")
          return [nil, problem]
        end
        [snapshot, nil]
      end

      def read_control
        body = @client.control
        body.is_a?(Hash) ? body : {}
      rescue Error => e
        log("control read failed: #{e.message}")
        {}
      end

      def claim_tasks
        body = @client.claim(limit: @config.claim_limit, kinds: @config.kinds,
          lease_seconds: lease_seconds)
        Array(body["tasks"])
      rescue Error => e
        log("claim failed: #{e.message}")
        []
      end

      def heartbeat(task_id, lease)
        @client.heartbeat(task_id, lease, seconds: lease_seconds)
        write_heartbeat
      rescue Error => e
        log("heartbeat failed: #{e.message}")
      end

      def post_answer(task, question, proposal, model:)
        decision_id = question["id"].to_s
        return "the task names no decision question" if decision_id.empty?

        model_name = proposal.dig("provenance", "model").to_s
        model_name = model.to_s if model_name.empty?
        payload = {
          "choice" => proposal["choice"],
          "stance" => proposal["stance"],
          "rationale" => proposal["rationale"],
          "effects" => proposal["effects"],
          "needs" => proposal["needs"],
          "evidence" => Array(proposal["evidence"]),
          "provenance" => proposal["provenance"].merge("model" => model.to_s),
          "proposed_by" => "model:#{model_name}"
        }
        body = @client.propose_answer(decision_id, payload)
        { "answer_id" => body["proposed_answer"].to_s }
      rescue Error => e
        raise e if e.retryable?

        e.message
      end

      def post_profile(task, proposal, model:)
        project_id = task["project_id"].to_s
        return "the task names no project" if project_id.empty?

        body = @client.propose_profile(project_id, {
          "fields" => proposal["fields"],
          "evidence" => proposal["evidence"],
          "provenance" => proposal["provenance"].merge("model" => model.to_s)
        })
        { "profile_proposal_id" => body["id"].to_s }
      rescue Error => e
        raise e if e.retryable?

        e.message
      end

      # **The review POST is the completion.** The service stores the verdict, completes the lease
      # and runs the gate; the loop must not call `complete` again on a task that is already done.
      def post_review(task, question, proposal, model:, seconds: 0, tokens_in: 0, tokens_out: 0)
        decision_id = question["id"].to_s
        answer_id = task.dig("context", "answer_id").to_s
        return "the review task names no decision question" if decision_id.empty?
        return "the review task names no answer" if answer_id.empty?

        payload = {
          "lease_token" => task["lease_token"].to_s,
          "verdict" => proposal["verdict"],
          "concerns" => Array(proposal["concerns"]),
          "evidence" => Array(proposal["evidence"]),
          "provenance" => proposal["provenance"].merge("model" => model.to_s),
          "rationale" => proposal["rationale"],
          # **A review costs tokens too.** The review POST completes its own task, so the normal
          # `complete` route never sees the spend; the endpoint records it from these fields.
          "tokens_in" => tokens_in.to_i,
          "tokens_out" => tokens_out.to_i,
          "calls" => 1,
          "seconds" => seconds.to_i
        }
        @client.review_answer(decision_id, answer_id, payload)
        { "answer_id" => answer_id, "verdict" => proposal["verdict"] }
      rescue Error => e
        raise e if e.retryable?

        e.message
      end

      # **A scan annotation is the result, not an effect.** It is stored on the task so a person
      # can read what the model said about the deterministic scan; nothing is proposed, applied or
      # turned into a question by the model. A person may create a question from it with the
      # `create_decision` tool, which is their act.
      def post_scan(proposal)
        {
          "annotations" => Array(proposal["annotations"]),
          "count" => Array(proposal["annotations"]).length,
          "stance" => proposal["stance"].to_s,
          "needs" => Array(proposal["needs"])
        }
      end

      # **A failed task still carries its spend.** The model ran, the validator or the service
      # refused its output, and the account's total must include the tokens that produced it.
      def fail_task(task_id, lease, message, retryable:, model: nil, usage: nil, seconds: 0)
        tokens_in = usage.is_a?(Hash) ? usage["tokens_in"].to_i : 0
        tokens_out = usage.is_a?(Hash) ? usage["tokens_out"].to_i : 0
        @client.fail(task_id, lease, error: message, retryable: retryable, model: model,
          tokens_in: tokens_in, tokens_out: tokens_out, calls: usage ? 1 : 0,
          seconds: seconds)
      rescue Error => e
        log("could not report the failure for #{task_id}: #{e.message}")
      end

      def model_for(task)
        policy = task["policy"].is_a?(Hash) ? task["policy"] : {}
        text = policy["model"].to_s
        text.empty? ? @config.model : text
      end

      def review_model_for(task)
        policy = task["policy"].is_a?(Hash) ? task["policy"] : {}
        text = policy["review_model"].to_s
        text = @config.review_model if text.empty?
        text.empty? ? model_for(task) : text
      end

      def record(task, prompt:, text:, result: nil, error: nil, model: nil, usage: nil)
        @config.records_dir.mkpath
        path = @config.records_dir.join("#{task['id']}.json")
        document = {
          "task_id" => task["id"].to_s,
          "kind" => task["kind"].to_s,
          "model" => model.to_s,
          "prompt_sha256" => Digest::SHA256.hexdigest(prompt.to_s),
          "output_sha256" => Digest::SHA256.hexdigest(text.to_s),
          "output_bytes" => text.to_s.bytesize,
          "result" => result,
          "error" => error,
          "usage" => usage,
          "recorded_at" => @clock.now.utc.iso8601
        }
        temp = "#{path}.tmp"
        File.write(temp, JSON.pretty_generate(document))
        File.rename(temp, path)
      rescue SystemCallError => e
        log("could not write the record for #{task['id']}: #{e.message}")
      end

      def write_heartbeat
        @config.state_dir.mkpath
        File.write(@config.state_dir.join("heartbeat.json"),
          JSON.generate("at" => @clock.now.utc.iso8601, "pid" => Process.pid))
      end

      # A lease shorter than the model call is a task the next consultant claims while this one is
      # still working. The timeout is the call's bound, so the lease is at least that plus a margin.
      def lease_seconds
        [@config.task_timeout.to_i + 120, LEASE_SECONDS].max
      end

      def sleep_interval
        seconds = @config.interval
        sleep(seconds) if seconds.positive?
      end

      # Raw model text is not stored (the record keeps hashes), so a live refusal is impossible to
      # diagnose from the service alone. This is opt-in for an operator running a probe by hand.
      def debug(message, text)
        return unless %w[1 true yes].include?(@config.env["CONSULTANT_DEBUG"].to_s.downcase)

        @err.puts("[consultant] #{message}")
        @err.puts(text.to_s[0, 8 * 1024])
      end

      def log(message)
        @out.puts("[consultant] #{message}")
      end
    end
  end
end
