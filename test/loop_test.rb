# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"

require "agents_fyi/consultant"

class LoopTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(answer: { "proposed_answer" => "a1" }, profile: { "id" => "p1" })
      @answer = answer
      @profile = profile
      @calls = []
    end

    def control = { "paused" => false, "reason" => nil }
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
  end

  class FakeRunner
    def initialize(text: nil, error: nil, usage: nil)
      @text = text
      @error = error
      @usage = usage
    end

    def run(prompt, model: nil, mode: nil, agent: nil)
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
    config = AgentsFyi::Consultant::Config.new(
      base_url: "http://service:8001", key: "afy_x", model: "provider/model",
      interval: 0, claim_limit: 1, kinds: %w[answer profile], task_timeout: 60,
      opencode_binary: "true", agent: "consultant", home: dir
    )
    AgentsFyi::Consultant::Loop.new(client: client, runner: runner, config: config,
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
      error = AgentsFyi::Consultant::ModelError.new("timeout", retryable: true)
      client = FakeClient.new
      subject = loop(client: client, runner: FakeRunner.new(error: error), dir: dir)

      subject.process(task)

      failed = client.calls.find { |call| call.first == :fail }
      assert_equal true, failed[2][:retryable]
      assert_equal "timeout", failed[2][:error]
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
                          "prompt_version" => "reviewer-prompt-1",
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
      refute client.calls.any? { |call| call.first == :complete },
        "the review POST completed the task; a second complete would race it"
    end
  end
end
