# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "errors"

module Agents
  module Consultant
    # **The task's own provider configuration, built from the fragment the service released.**
    #
    # The service stores the account's keys, but the client is the process that calls the provider.
    # This class turns the fragment into the two things opencode needs — a config document and an
    # environment that carries the secrets — and then removes both. The secret is never written to
    # the config: the file names the environment variable, and only the child process receives it.
    #
    # **Every task gets its own data and cache directories.** The deployment's `consultant_home`
    # may still hold an `opencode auth login` state from an earlier lifecycle; pointing the run's
    # XDG paths at empty directories means a missing lease cannot silently fall back to it. The
    # directories live under `state/model-access/<task>` and are deleted when the task ends.
    class ModelAccess
      ENV_NAME = /\AAGENTS_MODEL_KEY_[0-9a-f]{8}\z/
      SCHEMA = "https://opencode.ai/config.json"
      DIRECTORY = "model-access"

      def self.empty = new(payload: {}, directory: nil)

      def initialize(payload:, directory:, agents_dir: nil)
        @payload = payload.is_a?(Hash) ? payload : {}
        @directory = directory.to_s
        @agents_dir = agents_dir.to_s
      end

      def available?
        !providers.empty? && !keys.empty?
      end

      def chain
        Array(@payload["chain"]).map(&:to_s).reject(&:empty?)
      end

      def source = @payload["source"].to_s

      # **The credential that paid for this answer.** A fallback may cross providers, so the
      # caller asks by the model it actually ran, not by the first one in the chain.
      def credential_id_for(model)
        slug = model.to_s.split("/", 2).first
        row = keys[slug]
        row.is_a?(Hash) ? row["credential_id"].to_s : ""
      end

      # Yields the environment overrides for one task, with the config in place, and deletes the
      # directory afterwards. A block that raises still removes the secret's surroundings.
      def with_config
        return yield({}) unless available?

        FileUtils.mkdir_p(@directory, mode: 0o700)
        %w[data cache config].each { |name| FileUtils.mkdir_p(File.join(@directory, name), mode: 0o700) }
        write_config
        copy_agents
        yield environment
      ensure
        FileUtils.rm_rf(@directory) if available? && !@directory.empty?
      end

      def document
        {
          "$schema" => SCHEMA,
          "autoupdate" => false,
          "snapshot" => false,
          "provider" => providers.each_with_object({}) do |(slug, fragment), result|
            key = keys[slug]
            result[slug] = provider_entry(fragment, key) if key.is_a?(Hash)
          end
        }
      end

      private

      def providers
        @providers ||= @payload["providers"].is_a?(Hash) ? @payload["providers"] : {}
      end

      def keys
        @keys ||= @payload["keys"].is_a?(Hash) ? @payload["keys"] : {}
      end

      # **The agent definitions are part of the config, and the run's config is empty.**
      # Isolating `XDG_CONFIG_HOME` is what stops a leftover `opencode auth login` state from
      # being read; the same isolation hid `agents/consultant.md`, so the first live consultant
      # task failed with `Agent not found: "consultant"` *after* the service had handed over the
      # key. They are copied rather than referenced because opencode reads agents from the config
      # directory it is given, and the copy is removed with the rest of the directory.
      def copy_agents
        return if @agents_dir.empty? || !File.directory?(@agents_dir)

        destination = File.join(@directory, "config", "opencode", "agents")
        FileUtils.mkdir_p(destination, mode: 0o700)
        Dir.glob(File.join(@agents_dir, "*.md")).each do |path|
          FileUtils.cp(path, File.join(destination, File.basename(path)))
        end
      end

      def config_path = File.join(@directory, "opencode.json")

      def write_config
        path = config_path
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write("#{JSON.pretty_generate(document)}\n")
        end
        File.chmod(0o600, path)
      end

      def environment
        env = {}
        keys.each_value do |row|
          next unless row.is_a?(Hash)

          name = row["env_name"].to_s
          unless name.match?(ENV_NAME)
            raise ConfigError, "the service released a key with an unusable environment name"
          end

          env[name] = row["secret"].to_s
        end
        env["OPENCODE_CONFIG"] = config_path
        env["XDG_DATA_HOME"] = File.join(@directory, "data")
        env["XDG_CACHE_HOME"] = File.join(@directory, "cache")
        env["XDG_CONFIG_HOME"] = File.join(@directory, "config")
        env
      end

      def provider_entry(fragment, key)
        entry = {
          "name" => fragment["name"].to_s.empty? ? "provider" : fragment["name"].to_s,
          "models" => models_for(fragment)
        }
        npm = fragment["npm"].to_s
        entry["npm"] = npm unless npm.empty?

        options = {}
        base_url = fragment["base_url"].to_s
        options["baseURL"] = base_url unless base_url.empty?
        reference = "{env:#{key['env_name']}}"
        if fragment["auth_style"].to_s == "x-api-key"
          options["headers"] = { "x-api-key" => reference }
        else
          options["apiKey"] = reference
        end
        entry["options"] = options
        entry
      end

      def models_for(fragment)
        Array(fragment["models"]).each_with_object({}) do |row, result|
          next unless row.is_a?(Hash)

          id = row["id"].to_s.strip
          next if id.empty?

          result[id] = { "name" => row["name"].to_s.strip.empty? ? id : row["name"].to_s }
        end
      end
    end
  end
end
