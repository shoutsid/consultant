# frozen_string_literal: true

require "minitest/autorun"

require "agents_fyi/consultant"

class ValidatorTest < Minitest::Test
  def answer(effects:, stance: "answer")
    JSON.generate(
      "stance" => stance,
      "choice" => "guard the link",
      "rationale" => "the view renders a nil category",
      "effects" => effects,
      "needs" => [],
      "provenance" => { "model" => "test/model", "harness" => "test" }
    )
  end

  def patch(path, extra = {})
    { "kind" => "patch", "payload" => { "path" => path, "find" => "a", "replace" => "b" }.merge(extra) }
  end

  def test_a_safe_patch_is_read
    proposal, problem = AgentsFyi::Consultant::Validator.read(answer(effects: [patch("app/models/user.rb")]))

    assert_nil problem
    assert_equal "answer", proposal["stance"]
    assert_equal "pre", proposal["effects"].first["phase"]
    assert_equal "consultant/1", proposal["provenance"]["harness"]
  end

  def test_a_test_or_credential_path_is_refused
    %w[test/models/user_test.rb spec/user_spec.rb .github/workflows/ci.yml .env Gemfile
      config/credentials.yml.enc bin/rails].each do |path|
      proposal, problem = AgentsFyi::Consultant::Validator.read(answer(effects: [patch(path)]))

      assert_nil proposal, path
      assert_match(/may not propose/, problem, path)
    end
  end

  def test_a_whole_file_effect_is_refused_for_a_model
    effect = { "kind" => "file", "payload" => { "path" => "app/models/user.rb", "content" => "x" } }

    proposal, problem = AgentsFyi::Consultant::Validator.read(answer(effects: [effect]))

    assert_nil proposal
    assert_match(/whole-file/, problem)
  end

  def test_a_secret_in_an_effect_is_refused
    effect = patch("app/models/user.rb", params: { "replace" => "API_KEY = \"afy_canary_12345678\"" })

    proposal, problem = AgentsFyi::Consultant::Validator.read(answer(effects: [effect]))

    assert_nil proposal
    assert_match(/secret/, problem)
  end

  def test_maybe_and_cannot_carry_no_effects
    proposal, problem = AgentsFyi::Consultant::Validator.read(
      answer(effects: [patch("app/models/user.rb")], stance: "cannot")
    )

    assert_nil problem
    assert_equal [], proposal["effects"]

    proposal, problem = AgentsFyi::Consultant::Validator.read(
      answer(effects: [], stance: "answer")
    )
    assert_nil proposal
    assert_match(/at least one typed effect/, problem)
  end

  def test_a_model_output_with_no_json_is_a_refusal_not_a_crash
    proposal, problem = AgentsFyi::Consultant::Validator.read("I think you should guard it.")

    assert_nil proposal
    assert_match(/JSON/, problem)
  end

  def test_a_scan_annotation_is_not_an_effect_and_is_safe
    text = JSON.generate(
      "annotations" => [
        { "kind" => "missed", "path" => "app/controllers/users_controller.rb", "line" => 4,
          "subject" => "before_filter", "detail" => "the scan missed it",
          "effects" => [{ "kind" => "patch",
                          "payload" => { "path" => "app/controllers/users_controller.rb",
                                         "find" => "before_filter :x", "replace" => "before_action :x" } }] },
        { "kind" => "not_present", "path" => "config/application.rb",
          "detail" => "the setting has no call site" }
      ],
      "provenance" => { "model" => "test/model" }
    )
    proposal, problem = AgentsFyi::Consultant::Validator.read_scan(text)

    assert_nil problem
    assert_equal %w[missed not_present], proposal["annotations"].map { |row| row["kind"] }
    assert_equal "patch", proposal["annotations"].first["effects"].first["kind"]

    unsafe = JSON.generate(
      "annotations" => [{ "kind" => "missed", "path" => "spec/user_spec.rb",
                          "effects" => [patch("spec/user_spec.rb")] }],
      "provenance" => { "model" => "test/model" }
    )
    proposal, problem = AgentsFyi::Consultant::Validator.read_scan(unsafe)
    assert_nil proposal
    assert_match(/may not propose/, problem)
  end

  def test_a_repair_effect_is_post_update
    text = JSON.generate(
      "stance" => "answer", "choice" => "repair the view", "rationale" => "the move changed it",
      "effects" => [patch("app/views/layouts/application.html.erb")],
      "needs" => [], "provenance" => { "model" => "test/model" }
    )
    proposal, problem = AgentsFyi::Consultant::Validator.read(text, mode: "repair")

    assert_nil problem
    assert_equal "post", proposal["effects"].first["phase"]
  end

  def test_a_profile_refuses_an_unknown_field_and_a_secret
    text = JSON.generate("fields" => { "checks" => { "value" => [] } },
      "provenance" => { "model" => "test/model" })
    proposal, problem = AgentsFyi::Consultant::Validator.read_profile(text)
    assert_nil problem
    assert proposal.dig("fields", "checks")

    text = JSON.generate("fields" => { "invented" => { "value" => true } },
      "provenance" => { "model" => "test/model" })
    proposal, problem = AgentsFyi::Consultant::Validator.read_profile(text)
    assert_nil proposal
    assert_match(/not one the consultant may propose/, problem)
  end

  def review_text(verdict: "safe", evidence: nil, agent: "reviewer")
    JSON.generate(
      "verdict" => verdict,
      "concerns" => verdict == "safe" ? [] : [{ "kind" => "widened_change",
        "detail" => "the patch touches a second file", "path" => "app/models/user.rb" }],
      "evidence" => evidence || [{ "kind" => "run", "detail" => "the patch applies",
                                   "path" => "app/models/user.rb", "line" => 3 }],
      "rationale" => "the effect is the failure",
      "provenance" => { "model" => "test/model", "agent" => agent,
                        "prompt_version" => "reviewer-prompt-1",
                        "files_read" => ["app/models/user.rb"] }
    )
  end

  def test_a_safe_review_needs_evidence_and_a_reviewer_agent
    proposal, problem = AgentsFyi::Consultant::Validator.read_review(review_text)

    assert_nil problem
    assert_equal "safe", proposal["verdict"]
    assert_equal "reviewer", proposal.dig("provenance", "agent")

    proposal, problem = AgentsFyi::Consultant::Validator.read_review(
      review_text(evidence: [])
    )
    assert_nil proposal
    assert_match(/evidence/, problem)

    proposal, problem = AgentsFyi::Consultant::Validator.read_review(
      review_text(agent: "consultant")
    )
    assert_nil proposal
    assert_match(/provenance/, problem)
  end

  def test_an_unsafe_review_keeps_its_concerns
    proposal, problem = AgentsFyi::Consultant::Validator.read_review(
      review_text(verdict: "unsafe")
    )

    assert_nil problem
    assert_equal "widened_change", proposal["concerns"].first["kind"]
    assert_equal "app/models/user.rb", proposal["concerns"].first["path"]
  end
end
