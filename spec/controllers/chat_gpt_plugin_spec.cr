require "../helper"

module PlaceOS::Api
  describe ChatGPT::Plugin do
    router = ActionController::SpecHelper.new
    MCP.mount(router)
    mcp_client = router.hot_topic

    mcp_path = ->(sys_id : String) { "/api/engine/v2/chatgpt/plugin/#{sys_id}/mcp" }
    rpc = ->(path : String, headers : HTTP::Headers, method : String, params : Hash(String, JSON::Any)) {
      mcp_client.post(path, headers: headers, body: {jsonrpc: "2.0", id: 1, method: method, params: params}.to_json)
    }

    # establishes a session at the system's endpoint, returning the headers to use for it
    open_session = ->(sys_id : String, credentials : HTTP::Headers) {
      headers = credentials.dup
      headers["Content-Type"] = "application/json"
      headers["Accept"] = "application/json"
      headers["Host"] = "localhost"
      response = rpc.call(mcp_path.call(sys_id), headers, "initialize", {"protocolVersion" => JSON::Any.new("2025-11-25")})
      response.status_code.should eq 200
      headers["Mcp-Session-Id"] = response.headers["Mcp-Session-Id"]
      {headers, JSON.parse(response.body)["result"]}
    }
    call_tool = ->(sys_id : String, headers : HTTP::Headers, name : String, arguments : Hash(String, JSON::Any)) {
      response = rpc.call(mcp_path.call(sys_id), headers, "tools/call", {"name" => JSON::Any.new(name), "arguments" => JSON::Any.new(arguments)})
      response.status_code.should eq 200
      JSON.parse(response.body)["result"]
    }

    # a module with its driver interface seeded, returning its id
    create_module = ->(module_name : String, functions : Hash(String, Hash(String, JSON::Any))) {
      driver = Model::Generator.driver(role: Model::Driver::Role::Logic)
      driver.module_name = module_name
      driver.save!
      mod = Model::Generator.module(driver: driver)
      mod.running = true
      mod.save!

      module_id = mod.id.as(String)
      ::PlaceOS::Driver::RedisStorage.with_redis do |redis|
        meta = ::PlaceOS::Driver::DriverModel::Metadata.new(functions, ["Place::#{module_name}"])
        redis.set("interface/#{module_id}", meta.to_json)
      end
      module_id
    }

    it "serves the system's capabilities as an MCP endpoint" do
      llm_id = create_module.call("LLM", {} of String => Hash(String, JSON::Any))
      set_power = {"set_power" => {"state" => JSON.parse(%({"type":"boolean"}))}}
      meet_ids = [create_module.call("Meet", set_power), create_module.call("Meet", set_power)]

      system = Model::Generator.control_system
      system.modules = [llm_id] + meet_ids
      system.save!
      sys_id = system.id.as(String)

      # the lookups core maintains. Core rebuilds them asynchronously when systems change,
      # which can replace seeded entries, so they're seeded before each call
      seed_lookups = -> {
        lookup = ::PlaceOS::Driver::RedisStorage.new(sys_id, "system")
        lookup["LLM/1"] = llm_id
        lookup["Meet/1"] = meet_ids[0]
        lookup["Meet/2"] = meet_ids[1]
      }

      ::PlaceOS::Driver::RedisStorage.new(llm_id)["prompt"] = {
        prompt:       "You help people use the boardroom",
        capabilities: [{id: "Meet_2", capability: "controls the room's displays"}],
        system_id:    sys_id,
      }.to_json
      ::PlaceOS::Driver::RedisStorage.new(meet_ids[1])["function_schemas"] = [
        {function: "set_power", description: "turns the displays on or off", parameters: {state: {type: "boolean"}}},
      ].to_json

      _, credentials = Spec::Authentication.authentication
      headers, result = open_session.call(sys_id, credentials)
      # the instructions are the class doc comment, which is only available once mcp.yml is generated
      result["serverInfo"]["name"].should eq "chat_gpt_plugin"

      # the routes are the tools, the system id comes from the URL
      response = rpc.call(mcp_path.call(sys_id), headers, "tools/list", {} of String => JSON::Any)
      tools = JSON.parse(response.body)["result"]["tools"].as_a
      tools.map(&.["name"].as_s).sort!.should eq ["call_function", "capabilities", "function_schema"]
      tools.each { |tool| tool["inputSchema"]["properties"].as_h.has_key?("system_id").should be_false }

      seed_lookups.call
      capabilities = call_tool.call(sys_id, headers, "capabilities", {} of String => JSON::Any)
      capabilities["isError"].should be_false
      capabilities["structuredContent"]["body"]["prompt"].should eq "You help people use the boardroom"
      capabilities["structuredContent"]["body"]["system_id"].should eq sys_id

      seed_lookups.call
      schema = call_tool.call(sys_id, headers, "function_schema", {"capability_id" => JSON::Any.new("Meet_2")})
      schema["structuredContent"]["body"][0]["function"].should eq "set_power"

      # function params as an object or a JSON string, on module index 2
      WebMock.stub(:post, /\/api\/core\/v1\/command\//).to_return(
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: "true",
      )
      [JSON.parse(%({"state": true})), JSON::Any.new(%({"state": true}))].each do |function_params|
        seed_lookups.call
        called = call_tool.call(sys_id, headers, "call_function", {
          "capability_id" => JSON::Any.new("Meet_2"),
          "function_name" => JSON::Any.new("set_power"),
          "body"          => JSON.parse({function_params: function_params}.to_json),
        })
        called["isError"].should be_false
        called["structuredContent"]["body"]["response"].should eq "true"
      end
    ensure
      WebMock.reset
    end

    it "is hidden from the global MCP server" do
      _, credentials = Spec::Authentication.authentication
      headers = credentials.dup
      headers["Content-Type"] = "application/json"
      headers["Accept"] = "application/json"
      headers["Host"] = "localhost"
      response = mcp_client.post(MCP::PATH, headers: headers, body: {jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "2025-11-25"}}.to_json)
      headers["Mcp-Session-Id"] = response.headers["Mcp-Session-Id"]
      response = mcp_client.post(MCP::PATH, headers: headers, body: {jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "list_toolboxes", arguments: {} of String => String}}.to_json)
      names = JSON.parse(response.body)["result"]["structuredContent"]["toolboxes"].as_a.map(&.["name"].as_s)
      names.should_not contain "chat_gpt_plugin"
    end

    it "rejects unknown systems and tokens without control access" do
      _, credentials = Spec::Authentication.authentication
      headers, _ = open_session.call("sys-unknown", credentials)
      call_tool.call("sys-unknown", headers, "capabilities", {} of String => JSON::Any)["structuredContent"]["status"].should eq 404

      # read only tokens can't run functions
      system = Model::Generator.control_system.save!
      sys_id = system.id.as(String)
      read_only = PlaceOS::Model::UserJWT::Scope.new("public", PlaceOS::Model::UserJWT::Scope::Access::Read)
      _, reader = Spec::Authentication.authentication(sys_admin: false, support: false, scope: [read_only])
      headers, _ = open_session.call(sys_id, reader)
      called = call_tool.call(sys_id, headers, "call_function", {
        "capability_id" => JSON::Any.new("Meet"),
        "function_name" => JSON::Any.new("set_power"),
        "body"          => JSON.parse(%({"function_params": {"state": true}})),
      })
      called["isError"].should be_true
      called["structuredContent"]["status"].should eq 403
    end
  end
end
