# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "timeout"

require_relative "errors"

module Agents
  module Consultant
    # **The model process, with no walker environment and no shell.**
    #
    # The consultant invokes `opencode run` in a scratch directory. It passes an allowlist of
    # variables (HOME, PATH, the XDG directories and the config path) rather than the process's
    # environment, because the latter carries the agent key and any deployment secret compose
    # happened to add. The prompt is an attached file rather than one argv string: a real repair
    # prompt is about 90 KB, and Linux refuses a single argument over 128 KB with E2BIG. The
    # process gets no route to a database or a Docker socket.
    #
    # A timeout is TERM then KILL: a model call that never returns must not hold the task lease for
    # ever. The runner returns the text it wrote; the loop validates it.
    class Runner
      ENV_ALLOWLIST = %w[HOME PATH LANG LC_ALL LC_CTYPE TMPDIR TEMP TMP XDG_CONFIG_HOME
        XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR NODE_OPTIONS SHELL OPENCODE_CONFIG].freeze

      # The model is told to keep the answer bounded; the clamp is what the process actually gets.
      MAX_PROMPT_BYTES = 128 * 1024
      # The attached file carries the prompt; this is the only argv text, so the prompt never has
      # to fit in one argument.
      MESSAGE = "The attached file contains the task and its evidence. Follow its instructions " \
                "and reply with exactly one JSON object."

      def initialize(binary:, agent:, scratch:, env: ENV, timeout: 600, out: nil, err: nil)
        @binary = binary.to_s
        @agent = agent.to_s
        @scratch = scratch.to_s
        @env = env
        @timeout = timeout.to_i
        @out = out
        @err = err
      end

      # `[text, nil, usage]` or `[nil, error, nil]`. The rejection is an `Error` whose
      # `retryable?` says whether the provider or the machine failed (true) or the model's output
      # was unusable (false). `usage` is the session's token and cost report, or nil when the
      # provider did not expose one.
      def run(prompt, model: nil, mode: nil, agent: nil)
        raise ConfigError, "the opencode binary is required" if @binary.empty?
        raise ConfigError, "the scratch directory is required" if @scratch.empty?

        FileUtils.mkdir_p(@scratch)
        # **The working directory is the scratch clone, not a flag.** opencode v2 dropped
        # `--dir`; the process is started with `chdir:` instead, which is the same instruction
        # without depending on a CLI spelling.
        prompt_path = write_prompt(prompt)
        name = agent.to_s.empty? ? @agent : agent.to_s
        argv = [@binary, "run", "--format", "json", "--agent", name]
        argv += ["--model", model] unless model.to_s.empty?
        argv += ["--file", prompt_path, MESSAGE]
        stdout, stderr, status = capture(argv)
        return [nil, ModelError.new("the model process was killed after #{@timeout}s",
          retryable: true), nil] if status == :timeout
        return [nil, ModelError.new("the model process failed: #{stderr.to_s.lines.last.to_s.strip}",
          retryable: true), nil] unless status.success?

        text, session_id = parse_stream(stdout)
        [text, nil, usage_for(session_id)]
      rescue Errno::ENOENT
        [nil, ConfigError.new("`#{@binary}` is not on PATH; the consultant cannot run a model")]
      rescue SystemCallError => e
        [nil, ModelError.new("the model process could not start: #{e.message}", retryable: true)]
      ensure
        File.delete(prompt_path) if prompt_path && File.exist?(prompt_path)
      end

      private

      # **The JSON stream is the model's answer and its session id.** The text parts are the
      # response; the id is what `session export` reads the token buckets from. A binary that does
      # not emit the stream (or a test double) falls back to its raw stdout, which is the shape
      # this runner had before usage was counted.
      def parse_stream(stdout)
        texts = []
        session_id = nil
        stdout.to_s.each_line do |line|
          event = JSON.parse(line)
          next unless event.is_a?(Hash)

          session_id ||= event["sessionID"].to_s
          part = event["part"].is_a?(Hash) ? event["part"] : {}
          texts << part["text"].to_s if event["type"] == "text" && part["text"].is_a?(String)
        rescue JSON::ParserError
          next
        end
        text = texts.join
        text = stdout.to_s.strip if text.empty?
        [text, session_id.to_s]
      end

      # The provider's own session report. The cache buckets are prompt tokens too; the reasoning
      # tokens are generated tokens. The total the service stores is the sum of both sides.
      def usage_for(session_id)
        return nil if session_id.to_s.empty?

        stdout, _stderr, status = capture([@binary, "session", "export", session_id])
        return nil unless status.respond_to?(:success?) && status.success?

        info = JSON.parse(stdout)["info"]
        tokens = info.is_a?(Hash) && info["tokens"].is_a?(Hash) ? info["tokens"] : {}
        cache = tokens["cache"].is_a?(Hash) ? tokens["cache"] : {}
        {
          "tokens_in" => tokens["input"].to_i + cache["read"].to_i + cache["write"].to_i,
          "tokens_out" => tokens["output"].to_i + tokens["reasoning"].to_i,
          "cost" => info.is_a?(Hash) ? info["cost"].to_f : 0.0
        }
      rescue JSON::ParserError, SystemCallError => e
        @err&.puts("consultant: the token usage for #{session_id} could not be read: #{e.message}")
        nil
      end

      def write_prompt(prompt)
        path = File.join(@scratch, "prompt-#{SecureRandom.hex(8)}.txt")
        File.write(path, clamp(prompt))
        path
      end

      def capture(argv)
        env = @env.to_h.slice(*ENV_ALLOWLIST)
        Open3.popen3(env, *argv, chdir: @scratch) do |stdin, stdout, stderr, wait|
          # **The prompt is a file, not stdin.** Writing it to stdin was harmless while the
          # process kept stdin open; the current opencode closes it at startup and the write
          # surfaced as a broken pipe that read like a failed process.
          stdin.close
          reader_out = Thread.new { stdout.read }
          reader_err = Thread.new { stderr.read }
          unless wait.join(@timeout)
            terminate(wait.pid)
            return [reader_out.value, reader_err.value, :timeout]
          end

          [reader_out.value, reader_err.value, wait.value]
        end
      end

      def terminate(pid)
        Process.kill("TERM", pid)
        sleep 2
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      def clamp(prompt)
        text = prompt.to_s
        return text if text.bytesize <= MAX_PROMPT_BYTES

        text.byteslice(0, MAX_PROMPT_BYTES).scrub
      end
    end
  end
end
