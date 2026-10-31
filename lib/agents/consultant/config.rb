# frozen_string_literal: true

require "pathname"

require_relative "errors"

module Agents
  module Consultant
    # **The deployment's knobs, read once.** The service URL and the agent key are required; every
    # other value has a conservative default. `CONSULTANT_MODEL` is the deployment's fallback chain;
    # a project's policy may name a narrower one, and the service's task is the authority.
    class Config
      attr_reader :base_url, :key, :model, :interval, :claim_limit, :kinds, :task_timeout,
        :opencode_binary, :agent, :review_agent, :present_agent, :review_model, :scan_model,
        :present_model, :home, :state_dir, :records_dir, :env

      def self.from_env(env = ENV)
        new(
          base_url: env["AGENTS_URL"].to_s,
          key: env["AGENTS_KEY"].to_s,
          model: env["CONSULTANT_MODEL"].to_s,
          interval: env.fetch("CONSULTANT_INTERVAL", "300").to_i,
          claim_limit: env.fetch("CONSULTANT_CLAIM_LIMIT", "1").to_i,
          kinds: env.fetch("CONSULTANT_KINDS", "answer,review,profile,scan,intent,repair,present")
            .split(",").map(&:strip).reject(&:empty?),
          task_timeout: env.fetch("CONSULTANT_TASK_TIMEOUT", "600").to_i,
          opencode_binary: env.fetch("CONSULTANT_OPENCODE", "opencode"),
          agent: env.fetch("CONSULTANT_AGENT", "consultant"),
          review_agent: env.fetch("CONSULTANT_REVIEW_AGENT", "reviewer"),
          present_agent: env.fetch("CONSULTANT_PRESENT_AGENT", "presenter"),
          review_model: env.fetch("CONSULTANT_REVIEW_MODEL", "").to_s,
          scan_model: env.fetch("CONSULTANT_SCAN_MODEL", "").to_s,
          present_model: env.fetch("CONSULTANT_PRESENT_MODEL", "").to_s,
          home: env.fetch("CONSULTANT_HOME", File.expand_path("~")),
          env: env
        )
      end

      def initialize(base_url:, key:, model:, interval:, claim_limit:, kinds:, task_timeout:,
        opencode_binary:, agent:, review_agent: "reviewer", present_agent: "presenter",
        review_model: "", scan_model: "", present_model: "", home:, env: ENV)
        @base_url = base_url.to_s
        @key = key.to_s
        @model = model.to_s
        @interval = interval.to_i
        @claim_limit = claim_limit.to_i.clamp(1, 5)
        @kinds = Array(kinds).map(&:to_s)
        @task_timeout = task_timeout.to_i.clamp(60, 3600)
        @opencode_binary = opencode_binary.to_s
        @agent = agent.to_s
        @review_agent = review_agent.to_s
        @present_agent = present_agent.to_s
        @review_model = review_model.to_s
        @scan_model = scan_model.to_s
        @present_model = present_model.to_s
        @home = Pathname.new(home.to_s)
        @env = env
        @state_dir = @home.join("state")
        @records_dir = @home.join("records")
      end

      def validate!
        raise ConfigError, "AGENTS_URL is required" if base_url.empty?
        raise ConfigError, "AGENTS_KEY is required" if key.empty?
        raise ConfigError, "CONSULTANT_OPENCODE is required" if opencode_binary.empty?
        raise ConfigError, "CONSULTANT_AGENT is required" if agent.empty?
        raise ConfigError, "CONSULTANT_REVIEW_AGENT is required" if review_agent.empty?
        raise ConfigError, "CONSULTANT_PRESENT_AGENT is required" if present_agent.empty?

        self
      end

      def scratch_root = @home.join("scratch")
    end
  end
end
