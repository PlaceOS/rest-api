require "./helper"

module PlaceOS::Api
  describe MCP do
    router = ActionController::SpecHelper.new
    MCP.mount(router)
    mcp_client = router.hot_topic
    mcp_headers = ->(credentials : HTTP::Headers) {
      headers = credentials.dup
      headers["Content-Type"] = "application/json"
      headers["Accept"] = "application/json"
      headers["Host"] = "localhost"
      headers
    }
    rpc = ->(headers : HTTP::Headers, method : String, params : Hash(String, JSON::Any)) {
      body = {jsonrpc: "2.0", id: 1, method: method, params: params}.to_json
      mcp_client.post(MCP::PATH, headers: headers, body: body)
    }
    initialize_params = {"protocolVersion" => JSON::Any.new("2025-11-25")}
    no_params = {} of String => JSON::Any

    # establishes a session, returning the headers to use for it
    open_session = ->(credentials : HTTP::Headers) {
      headers = mcp_headers.call(credentials)
      response = rpc.call(headers, "initialize", initialize_params)
      response.status_code.should eq 200
      headers["Mcp-Session-Id"] = response.headers["Mcp-Session-Id"]
      headers
    }
    call_tool = ->(headers : HTTP::Headers, name : String, arguments : Hash(String, JSON::Any)) {
      response = rpc.call(headers, "tools/call", {"name" => JSON::Any.new(name), "arguments" => JSON::Any.new(arguments)})
      response.status_code.should eq 200
      JSON.parse(response.body)["result"]
    }

    it "challenges unauthenticated clients with the protected resource metadata" do
      response = rpc.call(mcp_headers.call(HTTP::Headers.new), "initialize", initialize_params)
      response.status_code.should eq 401
      response.headers["WWW-Authenticate"].should eq %(Bearer resource_metadata="http://localhost/.well-known/oauth-protected-resource/api/engine/v2/mcp", scope="public")
      response.headers["Mcp-Session-Id"]?.should be_nil
    end

    it "rejects invalid credentials" do
      headers = mcp_headers.call(HTTP::Headers{"Authorization" => "Bearer not-a-token"})
      response = rpc.call(headers, "initialize", initialize_params)
      response.status_code.should eq 401
      response.headers["WWW-Authenticate"].should contain %(error="invalid_token")
    end

    it "accepts bearer tokens and API keys" do
      _, bearer = Spec::Authentication.authentication
      open_session.call(bearer)

      _, api_key = Spec::Authentication.x_api_authentication
      open_session.call(api_key)
    end

    it "lists the API resources as toolboxes, excluding the unsuitable controllers" do
      _, credentials = Spec::Authentication.authentication
      headers = open_session.call(credentials)

      toolboxes = call_tool.call(headers, "list_toolboxes", no_params)["structuredContent"]["toolboxes"].as_a.map(&.["name"].as_s)
      toolboxes.should contain "systems"
      toolboxes.should contain "zones"
      toolboxes.should contain "api_keys"
      description = ActionController::MCPServer.description
      controllers = description.toolboxes.map(&.controller)
      {Root, MQTT, PushNotifications, Webhook, TenantConsent, UrlProxy, PublicEvents, Uploads, Signage,
       Flux, WebRTC, ChatGPT, ChatGPT::Plugin, BuildMonitor, SignageAI}.each do |hidden|
        controllers.should_not contain hidden.name
      end
      controllers.should contain Systems.name

      description.tool?("short_url_redirect").should be_nil
      description.tool?("domains_lookup").should be_nil
      description.tool?("short_url_index").should_not be_nil
    end

    it "calls routes as the authenticated user" do
      _, credentials = Spec::Authentication.authentication
      headers = open_session.call(credentials)
      zone = Model::Generator.zone.save!

      call_tool.call(headers, "open_toolbox", {"name" => JSON::Any.new("zones")})["isError"].should be_false
      result = call_tool.call(headers, "zones_show", {"id" => JSON::Any.new(zone.id.as(String))})
      result["isError"].should be_false
      result["structuredContent"]["body"]["name"].should eq zone.name
    ensure
      zone.try &.destroy
    end

    it "challenges clients whose token stops working mid-session" do
      _, credentials = Spec::Authentication.authentication
      headers = open_session.call(credentials)
      headers["Authorization"] = "Bearer expired.or.revoked"
      response = rpc.call(headers, "tools/list", no_params)
      response.status_code.should eq 401
      response.headers["WWW-Authenticate"].should contain "resource_metadata="
    end

    it "treats tokens without an audience as unauthorized rather than failing" do
      token = JWT.encode({"sub" => "someone", "exp" => (Time.utc + 1.hour).to_unix}, "secret", JWT::Algorithm::HS256)
      response = client.get("/api/engine/v2/users/current", headers: HTTP::Headers{"Host" => "localhost", "Authorization" => "Bearer #{token}"})
      response.status_code.should eq 401
    end
  end
end
