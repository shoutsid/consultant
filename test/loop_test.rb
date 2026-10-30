# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"

require "agents/consultant"

class LoopTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(answer: { "proposed_answer" => "a1" }, profile: { "id" => "p1" },
      model_access: nil, model_access_error: nil)
      @answer = answer
      @profile = profile
      @model_access = model_access
      @model_access_error = model_access_error
      @calls = []
    end

    def control = { "paused" => false, "reason" => nil }

    def model_access(task_id, lease_token)
      @calls << [:model_access, task_id, lease_token]
      raise @model_access_error if @model_access_error

      @model_access || {
        "chain" => ["provider/model"], "source" => "project",
        "providers" => { "provider" => { "name" => "Provider",
          "models" => [{ "id" => "model", "name" => "Model" }] } },
        "keys" => { "provider" => { "credential_id" => "cred-1",
          "env_name" => "AGENTS_MODEL_KEY_deadbeef", "secret" => "sk-test" } }
      }
    end

    def claim(**) = { "tasks" => [] }
    def heartbeat(*args, **kwargs) = @calls << [:heartbeat, args, kwargs]
    def complete(*args, **kwargs) = @calls << [:complete, args, kwargs]
    def fail(*args, **kwargs) = @calls << [:fail, args, kwargs]
    def propose_answer(id, body) = (@calls << [:answer, id, body]) && @answer
    def propose_profile(id, body) = (@calls << [:profile, id, body]) && @profile

    def review_answer(decision_id, answer_id, body)
      (@calls << [:review, decision_id, answer_id, body]) && { "reviewed_answer" => answer_id }
    end

    def run(id) = (@calls << [:run, id]) && { "patch" => "diff" }

    def presentation(run_id)
      (@calls << [:presentation, run_id]) && {
        "state" => "requested",
        "input" => {
          "presentation" => { "body" => "## What moved\n\nThe suite passed." },
          "fact_sheet" => { "run" => { "verdict" => "passed", "from_version" => "7.0.0",
                                       "to_version" => "7.1.0" },
                            "changed_paths" => ["app/models/user.rb"] },
          "guide" => { "rules" => ["A project rule"], "template" => "## Description",
                       "examples" => [] }
        }
      }
    end
  end

  class FakeRunner
    attr_reader :calls

    def initialize(text: nil, error: nil, usage: nil, responses: nil)
      @text = text
      @error = error
      @usage = usage
      @responses = responses
      @calls = []
    end

    def run(prompt, model: nil, mode: nil, agent: nil, env: nil)
      @calls << { model: model, mode: mode, agent: agent, env: env }
      if @responses
        text, error, usage = @responses.fetch(model)
        return [text, error, usage]
      end
      return [nil, @error, nil] if @error

      [@text, nil, @usage]
    end
  end

  def task(kind: "answer", question: true)
    {
      "id" => "task-1", "kind" => kind, "attempts" => 1, "max_attempts" => 2,
      "policy" => { "policy" => "propose", "model" => "provider/model" },
      "project_id" => "project-1",
      "question" => question ? { "id" => "q1", "question" => "What should happen?",
                                 "project" => "app", "rung_from" => "7.0.0",
                                 "rung_to" => "7.1.0", "context" => {}, "evidence" => {} } : nil
    }
  end

  def answer_text(stance: "answer")
    JSON.generate(
      "stance" => stance, "choice" => "guard the link", "rationale" => "the nil",
      "effects" => stance == "answer" ? [{ "kind" => "patch",
        "payload" => { "path" => "app/models/user.rb", "find" => "a", "replace" => "b" } }] : [],
      "needs" => [], "provenance" => { "model" => "provider/model" }
    )
  end

  def loop(client:, runner:, dir:)
    config = Agents::Consultant::Config.new(
      base_url: "http://service:8001", key: "afy_x", model: "provider/model",
      interval: 0, claim_limit: 1, kinds: %w[answer profile], task_timeout: 60,
      opencode_binary: "true", agent: "consultant", home: dir
    )
    Agents::Consultant::Loop.new(client: client, runner: runner, config: config,
      out: StringIO.new, err: StringIO.new)
  end

  def test_an_answer_is_posted_and_the_task_completed
    Dir.mktmpdir do |dir|
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(text: answer_text), dir: dir)

      result = subject.process(task)

      assert_equal "a1", result
      posted = client.calls.find { |call| call.first == :answer }
      assert_equal "answer", posted[2]["stance"]
      assert_equal "app/models/user.rb", posted[2]["effects"].first["payload"]["path"]
      assert client.calls.any? { |call| call.first == :complete }
      assert File.exist?(File.join(dir, "records", "task-1.json"))
      refute_includes File.read(File.join(dir, "records", "task-1.json")), "What should happen?",
        "the record stores a prompt hash, not the prompt"
    end
  end

  def test_a_present_task_reads_the_presentation_and_completes_with_the_lead
    Dir.mktmpdir do |dir|
      client = FakeClient.new
      runner = FakeRunner.new(text: JSON.generate(
        "summary" => "The suite passed and the only application edit is the serialize call in User.",
        "review_focus" => [{ "anchor" => "path:app/models/user.rb",
                             "why" => "the serialize call is the one behavioural change in this rung." }],
        "narrative" => {
          "what_moved" => "This rung moves the application from 7.0.0 to 7.1.0 and keeps the " \
            "suite green in the only application change.",
          "what_changed" => "The User model's serialize call changes and nothing else in the " \
            "application does; the dependency set moves with the rung."
        },
        "provenance" => { "model" => "provider/model",
                          "prompt_version" => "presenter-prompt-2" }
      ))
      subject = loop(client: client, runner: runner, dir: dir)

      result = subject.process(task(kind: "present", question: false).merge("run_id" => "run-1"))

      assert_includes result, "serialize call"
      assert client.calls.any? { |call| call.first == :presentation && call[1] == "run-1" }
      complete = client.calls.find { |call| call.first == :complete }
      assert_equal "path", complete[2][:result]["review_focus"].first["anchor"].split(":").first
      assert_includes complete[2][:result].dig("narrative", "what_moved"), "This rung moves"
      assert_equal "presenter", runner.calls.first[:agent]
      refute client.calls.any? { |call| call.first == :answer }
    end
  end

  # **The fragment is read after the claim, and the completion names the key that paid.** The
  # config lives for one task: the block that runs the model removes it even when the task fails.
  def test_a_task_reads_the_provider_fragment_after_claiming_and_names_the_credential
    Dir.mktmpdir do |dir|
      client = FakeClient.new
      runner = FakeRunner.new(text: answer_text)
      subject = loop(client: client, runner: runner, dir: dir)

      subject.process(task)

      kinds = client.calls.map(&:first)
      assert_operator kinds.index(:model_access), :>, kinds.index(:heartbeat),
        "the key was fetched before the lease was confirmed"
      complete = client.calls.find { |call| call.first == :complete }
      assert_equal "cred-1", complete[2][:model_credential_id]
      assert_equal "sk-test", runner.calls.first[:env]["AGENTS_MODEL_KEY_deadbeef"]
      refute Dir.exist?(File.join(dir, "state", "model-access", "task-1")),
        "the per-task config outlived the task"
    end
  end

  # **A missing key is the service's sentence, and the model is not started.** The refusal names
  # a provider a person has to connect; retrying the same task cannot fix it.
  def test_a_refused_provider_fragment_fails_the_task_without_calling_the_model
    Dir.mktmpdir do |dir|
      error = Agents::Consultant::Error.new("nano-gpt has no usable credential",
        status: 409, retryable: false)
      client = FakeClient.new(model_access_error: error)
      runner = FakeRunner.new(text: answer_text)
      subject = loop(client: client, runner: runner, dir: dir)

      subject.process(task)

      assert_empty runner.calls, "the model ran without a credential"
      failed = client.calls.find { |call| call.first == :fail }
      assert_equal "nano-gpt has no usable credential", failed[2][:error]
      assert_equal false, failed[2][:retryable]
    end
  end

  def test_a_completion_reports_the_session_token_usage
    Dir.mktmpdir do |dir|
      client = FakeClient.new
      subject = loop(client: client,
        runner: FakeRunner.new(text: answer_text,
          usage: { "tokens_in" => 12, "tokens_out" => 5, "cost" => 0.001 }), dir: dir)

      subject.process(task)

      complete = client.calls.find { |call| call.first == :complete }
      assert_equal 12, complete[2][:tokens_in]
      assert_equal 5, complete[2][:tokens_out]
      record = JSON.parse(File.read(File.join(dir, "records", "task-1.json")))
      assert_equal 12, record.dig("usage", "tokens_in")
    end
  end

  def test_a_model_failure_is_reported_retryable
    Dir.mktmpdir do |dir|
      error = Agents::Consultant::ModelError.new("timeout", retryable: true)
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(error: error), dir: dir)

      subject.process(task)

      failed = client.calls.find { |call| call.first == :fail }
      assert_equal true, failed[2][:retryable]
      assert_equal "timeout", failed[2][:error]
    end
  end

  def test_the_deployment_chain_is_read_when_the_task_policy_names_none
    Dir.mktmpdir do |dir|
      config = Agents::Consultant::Config.new(
        base_url: "http://service:8001", key: "afy_x",
        model: "free/config,paid/config", interval: 0, claim_limit: 1,
        kinds: %w[answer], task_timeout: 60, opencode_binary: "true",
        agent: "consultant", home: dir
      )
      subject = Agents::Consultant::Loop.new(client: FakeClient.new,
        runner: FakeRunner.new(text: answer_text), config: config,
        out: StringIO.new, err: StringIO.new)

      assert_equal %w[free/config paid/config], subject.send(:model_chain_for, { "policy" => {} })
      assert_equal %w[review/free review/paid],
        subject.send(:review_model_chain_for,
          { "policy" => { "review_model" => "review/free review/paid" } })
    end
  end

  def test_a_free_model_failure_falls_back_to_the_next_model
    Dir.mktmpdir do |dir|
      error = Agents::Consultant::ModelError.new("Rate limit exceeded. Please try again later.",
        retryable: true)
      runner = FakeRunner.new(responses: {
        "free/model" => [nil, error, nil],
        "paid/model" => [answer_text, nil, { "tokens_in" => 3, "tokens_out" => 4 }]
      })
      client = FakeClient.new
      subject = loop(client: client, runner: runner, dir: dir)

      subject.process(task.merge("policy" => { "policy" => "propose",
        "model" => "free/model,paid/model" }))

      assert_equal %w[free/model paid/model], runner.calls.map { |call| call[:model] }
      complete = client.calls.find { |call| call.first == :complete }
      assert_equal "paid/model", complete[2][:model]
      assert_equal 2, complete[2][:calls]
      assert_equal 3, complete[2][:tokens_in]
      assert_equal 2, client.calls.count { |call| call.first == :heartbeat },
        "the lease is extended before the fallback model runs"
      refute client.calls.any? { |call| call.first == :fail }
    end
  end

  def test_a_non_retryable_model_error_does_not_spend_the_fallback
    Dir.mktmpdir do |dir|
      error = Agents::Consultant::ModelError.new("the binary is not configured", retryable: false)
      runner = FakeRunner.new(responses: {
        "free/model" => [nil, error, nil],
        "paid/model" => [answer_text, nil, nil]
      })
      client = FakeClient.new
      subject = loop(client: client, runner: runner, dir: dir)

      subject.process(task.merge("policy" => { "policy" => "propose",
        "model" => "free/model,paid/model" }))

      assert_equal ["free/model"], runner.calls.map { |call| call[:model] }
      failed = client.calls.find { |call| call.first == :fail }
      assert_equal false, failed[2][:retryable]
      assert_equal "free/model", failed[2][:model]
    end
  end

  def test_a_validator_refusal_does_not_spend_the_fallback
    Dir.mktmpdir do |dir|
      bad = answer_text.sub("app/models/user.rb", "spec/models/user_spec.rb")
      runner = FakeRunner.new(responses: {
        "free/model" => [bad, nil, nil],
        "paid/model" => [answer_text, nil, nil]
      })
      client = FakeClient.new
      subject = loop(client: client, runner: runner, dir: dir)

      subject.process(task.merge("policy" => { "policy" => "propose",
        "model" => "free/model,paid/model" }))

      assert_equal ["free/model"], runner.calls.map { |call| call[:model] }
      failed = client.calls.find { |call| call.first == :fail }
      assert_equal false, failed[2][:retryable]
    end
  end

  def test_an_unsafe_proposal_is_a_permanent_failure_and_is_not_posted
    Dir.mktmpdir do |dir|
      text = answer_text.sub("app/models/user.rb", "spec/models/user_spec.rb")
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(text: text), dir: dir)

      subject.process(task)

      refute client.calls.any? { |call| call.first == :answer }
      failed = client.calls.find { |call| call.first == :fail }
      assert_equal false, failed[2][:retryable]
      assert_match(/may not propose/, failed[2][:error])
    end
  end

  def test_a_refused_proposal_still_reports_its_tokens
    Dir.mktmpdir do |dir|
      text = answer_text.sub("app/models/user.rb", "spec/models/user_spec.rb")
      client = FakeClient.new
      subject = loop(client: client,
        runner: FakeRunner.new(text: text,
          usage: { "tokens_in" => 7, "tokens_out" => 3 }), dir: dir)

      subject.process(task)

      failed = client.calls.find { |call| call.first == :fail }
      assert_equal 7, failed[2][:tokens_in]
      assert_equal 3, failed[2][:tokens_out]
    end
  end

  def test_a_scan_task_records_annotations_and_posts_no_answer
    Dir.mktmpdir do |dir|
      text = JSON.generate(
        "annotations" => [{ "kind" => "missed", "path" => "app/models/user.rb", "line" => 4,
                            "subject" => "attr_accessible", "detail" => "no call site reported" }],
        "provenance" => { "model" => "provider/model" }
      )
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(text: text), dir: dir)

      subject.process(task(kind: "scan"))

      rec = client.calls.find { |call| call.first == :complete }
      result = rec[2][:result]
      assert_equal 1, result["count"]
      assert_equal "missed", result["annotations"].first["kind"]
      refute client.calls.any? { |call| call.first == :answer }
    end
  end

  def test_a_repair_task_reads_the_run_its_question_names_in_evidence
    Dir.mktmpdir do |dir|
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(text: answer_text), dir: dir)
      repair = task(kind: "repair")
      repair["question"]["evidence"] = { "run_id" => "run-evidence" }

      subject.process(repair)

      assert_includes client.calls, [:run, "run-evidence"]
      assert client.calls.any? { |call| call.first == :complete }
    end
  end

  def test_a_profile_task_posts_fields
    Dir.mktmpdir do |dir|
      text = JSON.generate("fields" => { "suite" => { "value" => { "kind" => "minitest",
        "command" => "bin/rails test" } } }, "provenance" => { "model" => "provider/model" })
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(text: text), dir: dir)

      result = subject.process(task(kind: "profile"))

      assert_equal "p1", result
      posted = client.calls.find { |call| call.first == :profile }
      assert_equal "minitest", posted[2]["fields"]["suite"]["value"]["kind"]
    end
  end

  def test_a_review_task_posts_a_verdict_and_does_not_complete_twice
    Dir.mktmpdir do |dir|
      review_task = task(kind: "review").merge(
        "context" => { "answer_id" => "a1", "effect_digest" => "digest" },
        "lease_token" => "lease-1"
      )
      review_task["question"]["answers"] = [{ "id" => "a1", "choice" => "guard",
        "proposed_by" => "model:x", "stance" => "answer", "effects" => [] }]
      text = JSON.generate(
        "verdict" => "safe",
        "concerns" => [],
        "evidence" => [{ "kind" => "run", "detail" => "the patch applies to the failing file" }],
        "rationale" => "the effect is the failure",
        "provenance" => { "model" => "provider/model", "agent" => "reviewer",
                          "prompt_version" => "reviewer-prompt-2",
                          "files_read" => ["app/models/user.rb"] }
      )
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(text: text), dir: dir)

      result = subject.process(review_task)

      assert_equal "a1", result
      posted = client.calls.find { |call| call.first == :review }
      assert_equal "a1", posted[2]
      assert_equal "safe", posted[3]["verdict"]
      assert_equal "lease-1", posted[3]["lease_token"]
      assert_equal "cred-1", posted[3]["model_credential_id"]
      refute client.calls.any? { |call| call.first == :complete },
        "the review POST completed the task; a second complete would race it"
    end
  end
end
