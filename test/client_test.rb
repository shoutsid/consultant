# frozen_string_literal: true

require "minitest/autorun"
require "net/http"

require "agents/consultant"

class ClientTest < Minitest::Test
  class FakeHttp
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def request(uri, request)
      @requests << [uri, request]
      @responses.shift
    end
  end

  def response(klass, body, code: "200")
    row = klass.new("1.1", code, "OK")
    row.instance_variable_set(:@body, body)
    row.instance_variable_set(:@read, true)
    row
  end

  def client(*responses)
    Agents::Consultant::Client.new(base_url: "http://service:8001", key: "afy_agent_x",
      http: FakeHttp.new(*responses))
  end

  def test_a_claim_posts_the_bound_and_returns_the_tasks
    http = FakeHttp.new(response(Net::HTTPOK, JSON.generate("tasks" => [{ "id" => "t1" }])))
    subject = Agents::Consultant::Client.new(base_url: "http://service:8001",
      key: "afy_agent_x", http: http)

    body = subject.claim(limit: 1, lease_seconds: 900)

    assert_equal "t1", body["tasks"].first["id"]
    uri, request = http.requests.first
    assert_equal "/api/upgrades/agent/tasks/claim", uri.path
    assert_equal "afy_agent_x", request["X-API-Key"]
    assert_equal 1, JSON.parse(request.body)["limit"]
  end

  def test_a_4xx_refusal_is_not_retryable_and_a_5xx_is
    subject = client(response(Net::HTTPUnprocessableEntity,
      JSON.generate("error" => { "message" => "the project is off" }), code: "422"))

    error = assert_raises(Agents::Consultant::Error) do
      subject.post("/api/upgrades/agent/work", { "kind" => "answer" })
    end
    assert_equal 422, error.status
    refute error.retryable?
    assert_equal "the project is off", error.message

    subject = client(response(Net::HTTPInternalServerError, "{}", code: "500"))
    error = assert_raises(Agents::Consultant::Error) do
      subject.control
    end
    assert error.retryable?
  end

  def test_a_run_is_read_by_id
    http = FakeHttp.new(response(Net::HTTPOK, JSON.generate("run" => { "id" => "r1" },
      "patch" => "diff")))
    subject = Agents::Consultant::Client.new(base_url: "http://service:8001",
      key: "afy_agent_x", http: http)

    body = subject.run("r1")

    assert_equal "r1", body.dig("run", "id")
    assert_equal "/api/upgrades/runs/r1", http.requests.first.first.path
  end

  def test_a_query_is_encoded_and_a_missing_key_is_a_config_error
    assert_raises(Agents::Consultant::ConfigError) do
      Agents::Consultant::Client.new(base_url: "http://service:8001", key: "")
    end

    http = FakeHttp.new(response(Net::HTTPOK, "{}"))
    subject = Agents::Consultant::Client.new(base_url: "http://service:8001",
      key: "afy_agent_x", http: http)
    subject.get("/api/upgrades/projects/abc/resolution", { "from" => "7.0.0", "to" => "7.1.0" })

    assert_includes http.requests.first.first.query, "from=7.0.0"
  end
end
