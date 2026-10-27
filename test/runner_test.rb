# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require "agents/consultant"

class RunnerTest < Minitest::Test
  def test_a_large_prompt_is_attached_as_a_file_and_removed_after
    Dir.mktmpdir do |dir|
      binary = File.join(dir, "opencode")
      File.write(binary, <<~SH)
        #!/bin/sh
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--file" ]; then cat "$arg"; fi
          prev="$arg"
        done
      SH
      File.chmod(0o755, binary)
      runner = Agents::Consultant::Runner.new(binary: binary, agent: "consultant",
        scratch: File.join(dir, "scratch"))
      prompt = "x" * 100_000

      text, error = runner.run(prompt, model: "provider/model")

      assert_nil error
      assert_equal prompt, text, "the model reads the prompt from the attached file"
      assert_empty Dir[File.join(dir, "scratch", "prompt-*.txt")],
        "the prompt file does not outlive the call"
    end
  end

  def test_the_session_report_supplies_the_token_usage
    Dir.mktmpdir do |dir|
      binary = File.join(dir, "opencode")
      File.write(binary, <<~SH)
        #!/bin/sh
        if [ "$1" = "session" ] && [ "$2" = "export" ]; then
          echo '{"info":{"cost":0.0002,"tokens":{"input":10,"output":4,"reasoning":2,"cache":{"read":1,"write":0}}}}'
          exit 0
        fi
        echo '{"type":"text","sessionID":"ses_test","part":{"text":"{\\"ok\\":true}"}}'
      SH
      File.chmod(0o755, binary)
      runner = Agents::Consultant::Runner.new(binary: binary, agent: "consultant",
        scratch: File.join(dir, "scratch"))

      text, error, usage = runner.run("prompt", model: "provider/model")

      assert_nil error
      assert_equal '{"ok":true}', text
      assert_equal 11, usage["tokens_in"]
      assert_equal 6, usage["tokens_out"]
    end
  end
end
