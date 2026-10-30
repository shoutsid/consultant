# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"

require "agents/consultant"

class ModelAccessTest < Minitest::Test
  def payload(provider: "nano-gpt", auth_style: "bearer")
    {
      "chain" => ["#{provider}/deepseek/deepseek-v4.1-flash"],
      "source" => "account",
      "providers" => {
        provider => {
          "name" => "NanoGPT", "npm" => "@ai-sdk/openai-compatible",
          "base_url" => "https://api.nano-gpt.com/api/v1", "auth_style" => auth_style,
          "models" => [{ "id" => "deepseek/deepseek-v4.1-flash", "name" => "DeepSeek" }]
        }
      },
      "keys" => {
        provider => { "credential_id" => "cred-1",
                      "env_name" => "AGENTS_MODEL_KEY_deadbeef", "secret" => "sk-secret-7f3c" }
      }
    }
  end

  def test_the_config_is_private_names_the_provider_and_leaves_the_secret_in_the_environment
    Dir.mktmpdir do |dir|
      access = Agents::Consultant::ModelAccess.new(payload: payload, directory: File.join(dir, "task"))
      seen = nil

      access.with_config do |env|
        seen = env
        path = env.fetch("OPENCODE_CONFIG")
        assert_equal 0o600, File.stat(path).mode & 0o777
        text = File.read(path)
        refute_includes text, "sk-secret-7f3c", "the secret was written to the config"
        document = JSON.parse(text)
        entry = document.dig("provider", "nano-gpt")
        assert_equal "@ai-sdk/openai-compatible", entry["npm"]
        assert_equal "https://api.nano-gpt.com/api/v1", entry.dig("options", "baseURL")
        assert_equal "{env:AGENTS_MODEL_KEY_deadbeef}", entry.dig("options", "apiKey")
        assert entry.fetch("models").key?("deepseek/deepseek-v4.1-flash")
        assert_equal "sk-secret-7f3c", env.fetch("AGENTS_MODEL_KEY_deadbeef")
        assert_equal "task/data", env.fetch("XDG_DATA_HOME").delete_prefix(File.join(dir, ""))
      end

      assert_equal "cred-1", access.credential_id_for("nano-gpt/deepseek/deepseek-v4.1-flash")
      assert_empty access.credential_id_for("other/model")
      refute Dir.exist?(File.join(dir, "task")), "the per-task config was not removed"
      assert seen, "the environment was not yielded"
    end
  end

  def test_an_x_api_key_provider_names_its_header_rather_than_an_api_key_option
    Dir.mktmpdir do |dir|
      access = Agents::Consultant::ModelAccess.new(payload: payload(provider: "anthropic",
        auth_style: "x-api-key"), directory: File.join(dir, "task"))

      access.with_config do |env|
        entry = JSON.parse(File.read(env.fetch("OPENCODE_CONFIG"))).dig("provider", "anthropic")
        assert_equal({ "x-api-key" => "{env:AGENTS_MODEL_KEY_deadbeef}" },
          entry.dig("options", "headers"))
        refute entry.fetch("options").key?("apiKey")
      end
    end
  end

  # **The run's XDG config is empty by design, and that hid the agents.** Isolating the config
  # directory is what stops a leftover `opencode auth login` state from being read; the same
  # isolation hid `agents/consultant.md`, so the first live consultant task failed with
  # `Agent not found: "consultant"` after the service had already handed over the key. The
  # definitions are copied into the run and removed with it.
  def test_the_agent_definitions_are_copied_into_the_run_config
    Dir.mktmpdir do |dir|
      agents = File.join(dir, "agents")
      Dir.mkdir(agents)
      File.write(File.join(agents, "consultant.md"), "---\ndescription: x\n---\nthe consultant\n")
      target = File.join(dir, "task")

      access = Agents::Consultant::ModelAccess.new(payload: payload, directory: target,
        agents_dir: agents)
      copied = nil
      access.with_config do |env|
        copied = File.join(env.fetch("XDG_CONFIG_HOME"), "opencode", "agents", "consultant.md")
        assert File.file?(copied), "the agent definition was not copied into the run's config"
        assert_includes File.read(copied), "the consultant"
      end

      refute File.exist?(copied), "the copied definitions outlived the task"
    end
  end

  def test_an_empty_release_is_the_legacy_path_and_writes_nothing
    access = Agents::Consultant::ModelAccess.empty

    yielded = access.with_config { |env| env }

    assert_empty yielded
    refute access.available?
  end
end
