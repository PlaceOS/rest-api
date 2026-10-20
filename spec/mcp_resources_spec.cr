require "./helper"

MCP_RESOURCES_PORT = 6_131

# a 2026-07-28 MCP client, subscriptions need a real server as they're streamed
class MCPResourcesClient
  VERSION = "2026-07-28"
  META    = JSON.parse(%({"io.modelcontextprotocol/protocolVersion":"#{VERSION}","io.modelcontextprotocol/clientCapabilities":{}}))

  @headers : HTTP::Headers

  def initialize(credentials : HTTP::Headers)
    @headers = credentials.dup
    @headers["Content-Type"] = "application/json"
    @headers["Accept"] = "application/json, text/event-stream"
    @headers["Host"] = "localhost"
    @headers["MCP-Protocol-Version"] = VERSION
  end

  def prepare(id : Int32, method : String, params : Hash(String, JSON::Any)) : Tuple(HTTP::Headers, String)
    params = params.merge({"_meta" => META})
    headers = @headers.dup
    headers["Mcp-Method"] = method
    if method == "resources/read"
      headers["Mcp-Name"] = params["uri"].as_s
    end
    {headers, {jsonrpc: "2.0", id: id, method: method, params: params}.to_json}
  end

  # the final JSON-RPC message of the response
  def request(method : String, params = {} of String => JSON::Any) : JSON::Any
    headers, body = prepare(1, method, params)
    response = HTTP::Client.post("http://127.0.0.1:#{MCP_RESOURCES_PORT}#{PlaceOS::Api::MCP::PATH}", headers: headers, body: body)
    response.status_code.should eq 200
    return JSON.parse(response.body) unless response.content_type == "text/event-stream"
    events = response.body.split("\n\n").compact_map do |event|
      event.lines.find(&.starts_with?("data: ")).try { |data| JSON.parse(data.lchop("data: ")) }
    end
    events.last
  end

  def read(uri : String) : JSON::Any
    request("resources/read", {"uri" => JSON::Any.new(uri)})
  end

  # posts on a raw socket so the response can be read as it streams
  def stream(method : String, params : Hash(String, JSON::Any), &)
    headers, body = prepare(1, method, params)
    socket = TCPSocket.new("127.0.0.1", MCP_RESOURCES_PORT)
    socket.read_timeout = 2.seconds
    begin
      HTTP::Request.new("POST", PlaceOS::Api::MCP::PATH, headers, body).to_io(socket)
      socket.flush
      HTTP::Client::Response.from_io(socket) { |response| yield response.body_io }
    ensure
      socket.close
    end
  end

  # the next JSON-RPC message on an event stream, skipping keep-alive comments
  def self.next_event(io : IO) : JSON::Any?
    data = nil
    while line = io.gets(chomp: true)
      if line.empty?
        return JSON.parse(data) if data
        next
      end
      data = line.lchop("data: ") if line.starts_with?("data: ")
    end
  end
end

module PlaceOS::Api
  describe "MCP resources" do
    server = ActionController::Server.new(MCP_RESOURCES_PORT, "127.0.0.1")
    MCP.mount(server)

    before_all do
      bound = Channel(Nil).new
      spawn { server.run { bound.send nil } }
      bound.receive
    end

    after_all { server.close }

    it "lists the module state and logs resource templates" do
      client = MCPResourcesClient.new(Spec::Authentication.headers)
      result = client.request("resources/templates/list")["result"]
      templates = result["resourceTemplates"].as_a.map(&.["uriTemplate"].as_s)
      templates.should contain "placeos://modules/{id}/state"
      templates.should contain "placeos://modules/{id}/state/{key}"
      templates.should contain "placeos://systems/{sys_id}/{module_slug}/{key}"
      templates.should contain "placeos://modules/{id}/logs{?seconds,level}"

      discovered = client.request("server/discover")["result"]
      discovered["capabilities"]["resources"]["subscribe"].should be_true
    end

    it "reads module state by module and by system" do
      mod = Model::Generator.module.save!
      module_id = mod.id.as(String)
      control_system = Model::Generator.control_system
      control_system.modules = [module_id]
      control_system.save!
      wait_for_module_lookups(control_system.id.as(String), {"#{mod.resolved_name}/1" => module_id})
      PlaceOS::Driver::RedisStorage.new(module_id)["power"] = %({"on":true})

      client = MCPResourcesClient.new(Spec::Authentication.headers)
      uri = "placeos://modules/#{module_id}/state/power"
      contents = client.read(uri)["result"]["contents"][0]
      contents["uri"].should eq uri
      contents["mimeType"].should eq "application/json"
      JSON.parse(contents["text"].as_s).should eq JSON.parse(%({"on":true}))

      state = client.read("placeos://modules/#{module_id}/state")["result"]["contents"][0]
      JSON.parse(state["text"].as_s)["power"].should eq %({"on":true})

      by_system = client.read("placeos://systems/#{control_system.id}/#{mod.resolved_name}_1/power")["result"]["contents"][0]
      JSON.parse(by_system["text"].as_s).should eq JSON.parse(%({"on":true}))

      control_system.destroy
      mod.destroy
    end

    it "doesn't read module state without access" do
      mod = Model::Generator.module.save!
      client = MCPResourcesClient.new(Spec::Authentication.headers(sys_admin: false, support: false))
      error = client.read("placeos://modules/#{mod.id}/state/power")["error"]
      error["code"].should eq -32602
      error["message"].as_s.should start_with "403"
      mod.destroy
    end

    it "notifies subscribers when module state changes" do
      mod = Model::Generator.module.save!
      module_id = mod.id.as(String)
      storage = PlaceOS::Driver::RedisStorage.new(module_id)
      uri = "placeos://modules/#{module_id}/state/power"
      client = MCPResourcesClient.new(Spec::Authentication.headers)

      params = {"notifications" => JSON.parse({resourceSubscriptions: [uri, "placeos://modules/#{module_id}/logs"]}.to_json)}
      client.stream("subscriptions/listen", params) do |body|
        ack = MCPResourcesClient.next_event(body).should_not be_nil
        ack["method"].should eq "notifications/subscriptions/acknowledged"
        # logs can't be subscribed to
        ack["params"]["notifications"]["resourceSubscriptions"].should eq JSON.parse([uri].to_json)

        # every subscription is notified once acknowledged
        initial = MCPResourcesClient.next_event(body).should_not be_nil
        initial["params"]["uri"].should eq uri

        # redis pub/sub has no replay, so publish until the update arrives
        update = nil
        5.times do |attempt|
          storage["power"] = attempt
          update = MCPResourcesClient.next_event(body)
          break if update
        rescue IO::TimeoutError
        end
        update = update.should_not be_nil
        update["method"].should eq "notifications/resources/updated"
        update["params"]["uri"].should eq uri
        update["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq 1
      end

      mod.destroy
    end

    # the driver only delivers existing values, so unset values are notified by the watcher
    {nil, %({"on":true})}.each do |value|
      it "notifies each subscription once acknowledged, #{value ? "with" : "without"} a value" do
        mod = Model::Generator.module.save!
        module_id = mod.id.as(String)
        control_system = Model::Generator.control_system
        control_system.modules = [module_id]
        control_system.save!
        wait_for_module_lookups(control_system.id.as(String), {"#{mod.resolved_name}/1" => module_id})
        PlaceOS::Driver::RedisStorage.new(module_id)["power"] = value if value

        uris = [
          "placeos://modules/#{module_id}/state/power",
          "placeos://systems/#{control_system.id}/#{mod.resolved_name}_1/power",
        ]
        client = MCPResourcesClient.new(Spec::Authentication.headers)
        params = {"notifications" => JSON.parse({resourceSubscriptions: uris}.to_json)}
        client.stream("subscriptions/listen", params) do |body|
          ack = MCPResourcesClient.next_event(body).should_not be_nil
          ack["params"]["notifications"]["resourceSubscriptions"].as_a.map(&.as_s).sort!.should eq uris.sort

          # an existing value can be notified twice, by the watcher and by the driver
          updated = Set(String).new
          4.times do
            break if updated.size == uris.size
            update = MCPResourcesClient.next_event(body).should_not be_nil
            update["method"].should eq "notifications/resources/updated"
            updated << update["params"]["uri"].as_s
          end
          updated.should eq uris.to_set
        end

        # reading once notified returns the current value
        uris.each do |uri|
          contents = client.read(uri)["result"]["contents"][0]
          JSON.parse(contents["text"].as_s).should eq JSON.parse(value || "null")
        end

        control_system.destroy
        mod.destroy
      end
    end

    it "doesn't subscribe to module state without access" do
      mod = Model::Generator.module.save!
      client = MCPResourcesClient.new(Spec::Authentication.headers(sys_admin: false, support: false))
      params = {"notifications" => JSON.parse({resourceSubscriptions: ["placeos://modules/#{mod.id}/state/power"]}.to_json)}
      client.stream("subscriptions/listen", params) do |body|
        ack = MCPResourcesClient.next_event(body).should_not be_nil
        ack["params"]["notifications"].should eq JSON.parse("{}")
        # with nothing to watch the subscription completes
        MCPResourcesClient.next_event(body).should_not(be_nil)["result"]["resultType"].should eq "complete"
      end
      mod.destroy
    end

    it "captures module logs" do
      mod = Model::Generator.module.save!
      client = MCPResourcesClient.new(Spec::Authentication.headers)
      uri = "placeos://modules/#{mod.id}/logs?seconds=1&level=info"
      response = client.read(uri)
      # core may not be running the module, so either the capture or a debugger failure
      if result = response["result"]?
        contents = result["contents"][0]
        contents["uri"].should eq uri
        contents["mimeType"].should eq "text/plain"
        contents["text"].as_s.should be_a(String)
      else
        response["error"]["message"].as_s.should start_with "502"
      end
      mod.destroy
    end

    it "doesn't capture module logs without access" do
      mod = Model::Generator.module.save!
      client = MCPResourcesClient.new(Spec::Authentication.headers(sys_admin: false, support: false))
      error = client.read("placeos://modules/#{mod.id}/logs?seconds=1")["error"]
      error["message"].as_s.should start_with "403"
      mod.destroy
    end
  end
end
