# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "faraday"

RSpec.describe "example schema synthesis" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "synthesizes request/response structs from examples by default" do
    document = OpenapiSorbetClient::Parser.parse(fixture("example_only_body.yaml"))

    operation = document.operations.find { |op| op.method_name == "authenticates_the_user" }
    expect(operation.request_body).not_to be_nil
    expect(operation.request_body.schema.kind).to eq(:object)
    expect(operation.request_body.schema.name).to eq("AuthenticatesTheUserRequest")
    expect(operation.request_body.schema.properties.map(&:name)).to include(
      "user_name", "password", "realm", "is_internal"
    )
    user_name = operation.request_body.schema.properties.find { |p| p.name == "user_name" }
    expect(user_name.wire_key).to eq("UserName")
    expect(user_name.schema.ruby_type).to eq("String")
    is_internal = operation.request_body.schema.properties.find { |p| p.name == "is_internal" }
    expect(is_internal.schema.ruby_type).to eq("T::Boolean")

    expect(operation.success_response.schema.kind).to eq(:object)
    expect(operation.success_response.schema.name).to eq("AuthenticatesTheUserResponse")
    expect(operation.success_response.schema.properties.map(&:name)).to include("token")
  end

  it "leaves example-only bodies untyped when synthesis is disabled" do
    document = OpenapiSorbetClient::Parser.parse(
      fixture("example_only_body.yaml"),
      synthesize_from_examples: false
    )

    operation = document.operations.find { |op| op.method_name == "authenticates_the_user" }
    expect(operation.request_body.schema).to be_nil
    expect(operation.success_response.schema).to be_nil
  end

  it "emits a typed client that round-trips wire keys for synthesized bodies" do
    Dir.mktmpdir do |dir|
      document = OpenapiSorbetClient::Parser.parse(fixture("example_only_body.yaml"))
      OpenapiSorbetClient::Emitter.new(
        document: document,
        output: dir,
        module_name: "AuthLogin",
        gem_name: "auth_login_client"
      ).emit

      $LOAD_PATH.unshift(File.join(dir, "auth_login_client", "lib"))
      begin
        require "auth_login_client"

        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.post("/v1.0/Authenticate") do |env|
          payload = JSON.parse(env.body)
          expect(payload).to eq(
            "UserName" => "user",
            "Password" => "secret",
            "Realm" => "1",
            "UserSid" => "sid",
            "AdfsPilotLoginCode" => "code",
            "IsInternal" => true
          )
          [200, { "Content-Type" => "application/json" }, '{"Token":"abc"}']
        end

        connection = Faraday.new { |f| f.adapter(:test, stubs) }
        client = AuthLogin::Client.new(base_url: "https://example.com", connection: connection)
        body = AuthLogin::Models::AuthenticatesTheUserRequest.new(
          user_name: "user",
          password: "secret",
          realm: "1",
          user_sid: "sid",
          adfs_pilot_login_code: "code",
          is_internal: true
        )
        response = client.authenticates_the_user(body: body)
        expect(response.token).to eq("abc")
        stubs.verify_stubbed_calls
      ensure
        $LOAD_PATH.delete(File.join(dir, "auth_login_client", "lib"))
        Object.send(:remove_const, :AuthLogin) if defined?(AuthLogin)
      end
    end
  end
end
