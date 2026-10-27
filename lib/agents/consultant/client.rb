# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "errors"

module Agents
  module Consultant
    # **The service, over the task API and nothing else.** The consultant is a client with an agent
    # key: it has no database driver, no admin token and no route to the walker's files. Every method
    # here is one request, and the error carries the status so the loop can tell "the service refused
    # this proposal" from "the service is down".
    class Client
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60

      attr_reader :base_url

      def initialize(base_url:, key:, http: nil, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
        raise ConfigError, "AGENTS_URL is required" if base_url.to_s.empty?
        raise ConfigError, "AGENTS_KEY is required" if key.to_s.empty?

        @base_url = base_url.to_s.delete_suffix('/')
        @key = key.to_s
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @http = http
      end

      def control
        get("/api/upgrades/agent/control")
      end

      def claim(limit: 1, kinds: nil, lease_seconds: 900)
        body = { "limit" => limit, "lease_seconds" => lease_seconds }
        body["kinds"] = Array(kinds) if kinds && !Array(kinds).empty?
        post("/api/upgrades/agent/tasks/claim", body)
      end

      def heartbeat(task_id, lease_token, seconds: 900)
        post("/api/upgrades/agent/tasks/#{escape(task_id)}/heartbeat",
          { "lease_token" => lease_token, "seconds" => seconds })
      end

      def complete(task_id, lease_token, result:, model:, tokens_in: 0, tokens_out: 0,
        calls: 1, seconds: 0)
        post("/api/upgrades/agent/tasks/#{escape(task_id)}/complete", {
          "lease_token" => lease_token, "result" => result, "model" => model,
          "tokens_in" => tokens_in, "tokens_out" => tokens_out, "calls" => calls,
          "seconds" => seconds
        })
      end

      def fail(task_id, lease_token, error:, retryable:, model: nil, tokens_in: 0,
        tokens_out: 0, calls: 0, seconds: 0)
        post("/api/upgrades/agent/tasks/#{escape(task_id)}/fail",
          { "lease_token" => lease_token, "error" => error.to_s, "retryable" => retryable,
            "model" => model.to_s, "tokens_in" => tokens_in.to_i,
            "tokens_out" => tokens_out.to_i, "calls" => calls.to_i,
            "seconds" => seconds.to_i })
      end

      def release(task_id, lease_token)
        post("/api/upgrades/agent/tasks/#{escape(task_id)}/release",
          { "lease_token" => lease_token })
      end

      def decision(id)
        get("/api/upgrades/decisions/#{escape(id)}")
      end

      # The run that produced a block. Its patch is the evidence a repair question is about: the
      # question's own context names a file, but only the run says what changed in it.
      def run(id)
        get("/api/upgrades/runs/#{escape(id)}")
      end

      def resolution(project_id, from_version: nil, to_version: nil)
        params = {}
        params["from"] = from_version unless from_version.to_s.empty?
        params["to"] = to_version unless to_version.to_s.empty?
        get("/api/upgrades/projects/#{escape(project_id)}/resolution", params)
      end

      def propose_answer(decision_id, body)
        post("/api/upgrades/decisions/#{escape(decision_id)}/answers", body)
      end

      def propose_profile(project_id, body)
        post("/api/upgrades/projects/#{escape(project_id)}/profile_proposals", body)
      end

      def review_answer(decision_id, answer_id, body)
        post("/api/upgrades/decisions/#{escape(decision_id)}/answers/#{escape(answer_id)}/review",
          body)
      end

      def usage
        get("/api/upgrades/agent/usage")
      end

      def get(path, params = {})
        request("GET", path, params: params)
      end

      def post(path, body)
        request("POST", path, body: body)
      end

      private

      def request(method, path, params: {}, body: nil)
        uri = URI.parse("#{@base_url}#{path}")
        unless params.empty?
          uri.query = URI.encode_www_form(params.reject { |_key, value| value.nil? })
        end
        request = request_for(method, uri)
        request["X-API-Key"] = @key
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body) if body
        response = perform(uri, request)
        parsed = parse(response)
        return parsed if response.is_a?(Net::HTTPSuccess)

        message = parsed.is_a?(Hash) ? parsed.dig("error", "message") : nil
        # **The service's detail is the sentence a person acts on.** A bare "Request validation
        # failed" is the envelope's summary; the first field detail names the effect or the field
        # that was wrong, and a consultant that drops it makes every refusal look like a crash.
        detail = parsed.is_a?(Hash) ? Array(parsed.dig("error", "details")).first : nil
        detail = detail.is_a?(Hash) ? detail["message"].to_s : ""
        message = [message, detail].reject { |part| part.to_s.empty? }.join(": ")
        status = response.code.to_i
        raise Error.new(message.to_s.empty? ? "the service answered #{status}" : message,
          status: status, retryable: status >= 500 || [408, 429].include?(status))
      rescue Net::OpenTimeout, Net::ReadTimeout, EOFError, SocketError, Errno::ECONNREFUSED => e
        raise Error.new("the service is unreachable: #{e.class}: #{e.message}", retryable: true)
      rescue JSON::ParserError
        raise Error.new("the service answered something that is not JSON", retryable: true)
      end

      def request_for(method, uri)
        klass = method == "GET" ? Net::HTTP::Get : Net::HTTP::Post
        klass.new(uri)
      end

      def perform(uri, request)
        if @http
          @http.request(uri, request)
        else
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
            open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
            http.request(request)
          end
        end
      end

      def parse(response)
        text = response.body.to_s
        return {} if text.empty?

        JSON.parse(text)
      end

      def escape(value) = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end
  end
end
