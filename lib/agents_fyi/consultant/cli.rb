# frozen_string_literal: true

require "optparse"

require_relative "../consultant"

module AgentsFyi
  module Consultant
    # **A bounded run, or a loop a deployment starts.** `--once` is the probe and the CI check:
    # one control read and one claim, so a deployment with a broken key says so instead of retrying
    # silently for ever.
    class CLI
      def self.run(argv, env: ENV, out: $stdout, err: $stderr)
        options = { cycles: 1, tasks: nil }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: agents-fyi-consultant [--once|--cycles N] [--tasks N]"
          opts.on("--once", "One poll, then exit") { options[:cycles] = 1 }
          opts.on("--cycles N", Integer, "Poll N times") { |value| options[:cycles] = value }
          opts.on("--tasks N", Integer, "Stop after N tasks") { |value| options[:tasks] = value }
          opts.on("-h", "--help", "This help") do
            out.puts(opts)
            return 0
          end
        end
        parser.parse!(argv)

        config = Config.from_env(env).validate!
        client = Client.new(base_url: config.base_url, key: config.key)
        runner = Runner.new(binary: config.opencode_binary, agent: config.agent,
          scratch: config.scratch_root.to_s, env: env, timeout: config.task_timeout,
          out: out, err: err)
        loop = Loop.new(client: client, runner: runner, config: config, out: out, err: err)
        loop.run(cycles: options[:cycles], max_tasks: options[:tasks])
        0
      rescue ConfigError, Error => e
        err.puts("consultant: #{e.message}")
        2
      end
    end
  end
end
