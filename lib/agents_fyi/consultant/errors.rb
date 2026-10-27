# frozen_string_literal: true

module AgentsFyi
  module Consultant
    # **A refused request, with whether trying again could help.** The same distinction the miner
    # learned: a 4xx is the service reading this request and declining it, while a 5xx or a timeout
    # is the service being unavailable. A task whose proposal was refused is a person's; a task whose
    # provider timed out is work again.
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil, retryable: false)
        super(message)
        @status = status
        @retryable = retryable
      end

      def retryable? = @retryable
    end

    class ConfigError < Error; end
    class ModelError < Error; end
  end
end
