require "placeos-driver/storage"
require "webmock"

require "../helper"

module PlaceOS::Api::WebSocket
  describe Session do
    describe "systems/control" do
      it "opens a websocket session" do
        bind(Systems.base_route, Spec::Authentication.headers) do |ws|
          ws.closed?.should be_false
        end
      end
    end

    describe "websocket API" do
      describe "bind" do
        it "receives updates" do
          # Status to bind
          status_name = "nugget"
          results = test_websocket_api(Systems.base_route, Spec::Authentication.headers) do |ws, control_system, mod, updates|
            # Create a storage proxy
            driver_proxy = PlaceOS::Driver::RedisStorage.new mod.id.as(String)

            ws.send Session::Request.new(
              id: rand(10).to_i64,
              system_id: control_system.id.as(String),
              module_name: mod.resolved_name,
              name: status_name,
              command: Session::Request::Command::Bind,
            ).to_json
            # Gate each publish on the prior message arriving. The bind Success
            # confirms the redis subscription is live before we publish (pub/sub
            # has no replay), and waiting between publishes guarantees order and
            # that no notify is dropped before the assertions run.
            wait_for_updates(updates, 1)
            driver_proxy[status_name] = 1
            wait_for_updates(updates, 2)
            driver_proxy[status_name] = 2
            wait_for_updates(updates, 3)
          end

          updates, control_system, mod = results
          updates.should_not be_empty

          expected_meta = {
            sys:   control_system.id,
            mod:   mod.custom_name,
            index: 1,
            name:  status_name,
          }

          # Check for successful bind response
          updates.first.type.should eq Session::Response::Type::Success
          # Check all responses correct metadata
          updates.all? { |v| v.metadata == expected_meta }.should be_true
          # Check all messages received
          updates.size.should eq 3 # Check for status variable updates
          updates[1..2].compact_map(&.value.try &.to_i).should eq [1, 2]
        end
      end

      it "unbind" do
        # Status to bind
        status_name = "nugget"

        id = rand(10).to_i64
        results = test_websocket_api(Systems.base_route, Spec::Authentication.headers) do |ws, control_system, mod, updates|
          request = {
            id:          id,
            system_id:   control_system.id.as(String),
            module_name: mod.resolved_name,
            name:        status_name,
            command:     Session::Request::Command::Bind,
          }
          ws.send Session::Request.new(**request).to_json
          wait_for_updates(updates, 1)
          ws.send Session::Request.new(**request.merge({command: Session::Request::Command::Unbind})).to_json
          wait_for_updates(updates, 2)
        end

        updates, control_system, mod = results
        expected_meta = {sys: control_system.id, mod: mod.custom_name, index: 1, name: status_name}
        # Check all messages received
        updates.size.should eq 2
        # The bind response includes metadata; unbind is an acknowledgement.
        updates.first.metadata.should eq expected_meta
        # Check for successful bind response
        updates.shift.type.should eq Session::Response::Type::Success
        # Check for successful unbind response
        updates.shift.type.should eq Session::Response::Type::Success
      end

      it "exec" do
        WebMock.stub(:any, /^http:\/\/core:3000\/api\/core\/v1\/command\//).to_return(body: %({"__exec__":"function2"}))

        id = rand(10).to_i64

        status_name = "function2"

        id = rand(10).to_i64
        updates, _, _ = test_websocket_exec(Systems.base_route, Spec::Authentication.headers) do |ws, control_system, mod|
          request = {
            id:          id,
            system_id:   control_system.id.as(String),
            module_name: mod.resolved_name,
            name:        status_name,
            command:     Session::Request::Command::Exec,
          }
          ws.send Session::Request.new(**request).to_json
          sleep 100.milliseconds
        end

        # Check for successful exec response

        updates.first.type.should eq Session::Response::Type::Success
        updates.first.value.should eq(%({"__exec__":"function2"}))
      end

      it "debug" do
        status_name = "nugget"

        id = rand(10).to_i64
        updates, _, _ = test_websocket_api(Systems.base_route, Spec::Authentication.headers) do |ws, control_system, mod, ws_updates|
          # debug sessions are addressed by module id, not name (see Session#debug)
          request = {
            id:          id,
            system_id:   control_system.id.as(String),
            module_name: mod.id.as(String),
            name:        status_name,
            command:     Session::Request::Command::Debug,
          }
          ws.send Session::Request.new(**request).to_json
          wait_for_updates(ws_updates, 1)
        end

        # Check all messages received
        updates.size.should eq 1
        # Check for successful debug response
        updates.shift.type.should eq Session::Response::Type::Success
      end

      it "denies debug to users without access to the module" do
        id = rand(10).to_i64
        headers = Spec::Authentication.headers(sys_admin: false, support: false)
        updates, _, _ = test_websocket_api(Systems.base_route, headers) do |ws, control_system, mod, ws_updates|
          request = {
            id:          id,
            system_id:   control_system.id.as(String),
            module_name: mod.id.as(String),
            name:        "nugget",
            command:     Session::Request::Command::Debug,
          }
          ws.send Session::Request.new(**request).to_json
          wait_for_updates(ws_updates, 1)
        end

        updates.size.should eq 1
        error = updates.shift
        error.type.should eq Session::Response::Type::Error
        error.error_code.should eq Session::Response::ErrorCode::AccessDenied
      end

      it "ignore" do
        status_name = "nugget"

        id = rand(10).to_i64
        updates, _, _ = test_websocket_api(Systems.base_route, Spec::Authentication.headers) do |ws, control_system, mod, ws_updates|
          # debug sessions are addressed by module id, not name (see Session#debug)
          request = {
            id:          id,
            system_id:   control_system.id.as(String),
            module_name: mod.id.as(String),
            name:        status_name,
            command:     Session::Request::Command::Ignore,
          }
          ws.send Session::Request.new(**request).to_json
          wait_for_updates(ws_updates, 1)
        end

        # Check all messages received
        updates.size.should eq 1
        # Check for successful ignore response
        updates.shift.type.should eq Session::Response::Type::Success
      end
    end

    describe "driver interfaces" do
      it "parses iface and defaults to driver names for existing requests" do
        request = %({"id":1,"sys":"sys-test","mod":"Interface::Sensor","cmd":"bind","name":"reading"})
        Session::Request.from_json(request).interface?.should be_false
        Session::Request.from_json(request.sub("}", %(,"iface":true}))).interface?.should be_true
      end

      it "executes the indexed matching module in system order and preserves request metadata" do
        test_websocket_interfaces(Spec::Authentication.headers) do |ws, system, modules, updates|
          modules[1..2].each_with_index do |mod, offset|
            WebMock.stub(:post, /http:\/\/core:3000\/api\/core\/v1\/command\/#{mod.id}\/execute/)
              .with(body: {"__exec__" => "read", "read" => [42]}.to_json)
              .to_return(body: {"module_id" => mod.id}.to_json)
            ws.send interface_request(system, :exec, index: offset + 1, args: [JSON::Any.new(42_i64)]).to_json
            wait_for_updates(updates, offset + 1)
            response = updates.last
            response.type.should eq Session::Response::Type::Success
            JSON.parse(response.value.not_nil!)["module_id"].as_s.should eq mod.id
            response.metadata.should eq({sys: system.id, mod: "Interface::Sensor", index: offset + 1, name: "read"})
          end
        end
      end

      it "binds to the indexed interface and receives status updates" do
        test_websocket_interfaces(Spec::Authentication.headers) do |ws, system, modules, updates|
          request = interface_request(system, :bind, index: 2)
          ws.send request.to_json
          wait_for_updates(updates, 1)
          updates.first.type.should eq Session::Response::Type::Success
          # Repeated binds must share the same local binding.
          ws.send request.to_json
          wait_for_updates(updates, 2)
          PlaceOS::Driver::RedisStorage.new(modules[2].id.as(String))["read"] = 123
          wait_for_updates(updates, 3)
          sleep 50.milliseconds
          updates.size.should eq 3
          updates.last.type.should eq Session::Response::Type::Notify
          updates.last.value.should eq "123"
          updates.all? { |response| response.metadata == {sys: system.id, mod: "Interface::Sensor", index: 2, name: "read"} }.should be_true
        end
      end

      it "keeps interface bindings separate and unbinds after interface metadata disappears" do
        test_websocket_interfaces(Spec::Authentication.headers) do |ws, system, modules, updates|
          # The first module has the interface's name, but does not implement it.
          ws.send interface_request(system, :bind, interface: false).to_json
          wait_for_updates(updates, 1)
          ws.send interface_request(system, :bind).to_json
          wait_for_updates(updates, 2)
          updates.all?(&.type.success?).should be_true
          PlaceOS::Driver::RedisStorage.new(modules[1].id.as(String))["read"] = 11
          wait_for_updates(updates, 3)
          updates.last.value.should eq "11"

          PlaceOS::Driver::RedisStorage.with_redis do |redis|
            modules[1..2].each { |mod| redis.del("interface/#{mod.id}") }
          end
          ws.send interface_request(system, :unbind).to_json
          wait_for_updates(updates, 4)
          updates.last.type.should eq Session::Response::Type::Success
          PlaceOS::Driver::RedisStorage.new(modules[1].id.as(String))["read"] = 22
          PlaceOS::Driver::RedisStorage.new(modules[0].id.as(String))["read"] = 33
          wait_for_updates(updates, 5)
          sleep 50.milliseconds
          updates.size.should eq 5
          updates.last.value.should eq "33"
        end
      end

      it "returns not found for unmatched interfaces and invalid indices on exec and bind" do
        test_websocket_interfaces(Spec::Authentication.headers) do |ws, system, _, updates|
          count = 0
          [Session::Request::Command::Exec, Session::Request::Command::Bind].each do |command|
            [{"MissingInterface", 1}, {"Interface::Sensor", 0}, {"Interface::Sensor", -1}, {"Interface::Sensor", 3}].each do |name, index|
              ws.send interface_request(system, command, module_name: name, index: index).to_json
              wait_for_updates(updates, count += 1)
              response = updates.last
              response.type.should eq Session::Response::Type::Error
              response.error_code.should eq Session::Response::ErrorCode::ModuleNotFound
              response.response_code.should eq 404
            end
          end
        end
      end

      it "does not fall back to a matching driver name when iface is true" do
        test_websocket_api(Systems.base_route, Spec::Authentication.headers) do |ws, system, mod, updates|
          ws.send interface_request(system, :bind, module_name: mod.resolved_name).to_json
          wait_for_updates(updates, 1)
          updates.first.error_code.should eq Session::Response::ErrorCode::ModuleNotFound
          updates.first.response_code.should eq 404
        end
      end

      it "does not resolve interfaces from another system" do
        test_websocket_interfaces(Spec::Authentication.headers) do |ws, _, _, updates|
          other_system = PlaceOS::Model::Generator.control_system.save!
          [Session::Request::Command::Exec, Session::Request::Command::Bind].each_with_index do |command, index|
            ws.send interface_request(other_system, command).to_json
            wait_for_updates(updates, index + 1)
            updates.last.error_code.should eq Session::Response::ErrorCode::ModuleNotFound
            updates.last.response_code.should eq 404
          end
          other_system.destroy
        end
      end

      it "preserves function security for interface execution" do
        headers = Spec::Authentication.headers(sys_admin: false, support: false)
        test_websocket_interfaces(headers) do |ws, system, _, updates|
          ws.send interface_request(system, :exec, name: "restricted").to_json
          wait_for_updates(updates, 1)
          updates.first.type.should eq Session::Response::Type::Error
          updates.first.error_code.should eq Session::Response::ErrorCode::AccessDenied
        end
      end

      it "preserves protected-module restrictions for interface binding" do
        headers = Spec::Authentication.headers(sys_admin: false, support: false)
        test_websocket_interfaces(headers, protected_module: true) do |ws, system, _, updates|
          ws.send interface_request(system, :bind).to_json
          wait_for_updates(updates, 1)
          updates.first.type.should eq Session::Response::Type::Error
          updates.first.error_code.should eq Session::Response::ErrorCode::AccessDenied
        end
      end
    end

    describe Session::Response do
      it "scrubs invalid UTF-8 chars from the error message" do
        Session::Response.new(
          type: Session::Response::Type::Error,
          id: 1234_i64,
          message: String.new(Bytes[0xc3, 0x28]),
        ).to_json.should contain(Char::REPLACEMENT)
      end

      it "scrubs invalid UTF-8 chars from the payload" do
        Session::Response.new(
          type: Session::Response::Type::Success,
          id: 1234_i64,
          value: %({"invalid":"#{String.new(Bytes[0xc3, 0x28])}"})
        ).to_json.should contain(Char::REPLACEMENT)
      end
    end
  end
end

# Binds to the system websocket endpoint
#
# Polls `updates` until it holds at least `count` messages, yielding to the
# socket fiber between checks. Raises on timeout so a genuinely missing update
# fails loudly instead of racing against a fixed sleep. Redis pub/sub has no
# replay, so publishes must only be sent once the subscription is live (i.e.
# after the bind Success response has been observed).
def wait_for_updates(updates, count : Int32, timeout : Time::Span = 5.seconds) : Nil
  deadline = Time.monotonic + timeout
  until updates.size >= count
    raise "timed out waiting for #{count} websocket updates, got #{updates.size}" if Time.monotonic > deadline
    sleep 10.milliseconds
  end
end

def bind(base, auth, on_message : Proc(String, _) = ->(_msg : String) { }, &)
  host = "localhost"
  bearer = auth["Authorization"].split(' ').last
  path = File.join(base, "control?bearer_token=#{bearer}")

  # Create a websocket connection, then run the session
  socket = client.establish_ws(path, headers: HTTP::Headers{"Host" => host})

  socket.on_message &on_message

  spawn { socket.run }

  yield socket

  socket.close
end

# A ControlSystem containing a single Module, mapped as `<custom_name>/1`.
#
# The system is saved once with its module and the spec waits for core's
# lookup, which bindings resolve the module through. A lookup seeded by hand
# races core's asynchronous rebuild: core wipes it (publishing `lookup-change`,
# which remaps the binding onto nothing) and updates stop arriving.
def websocket_spec_system : {PlaceOS::Model::ControlSystem, PlaceOS::Model::Module}
  mod = PlaceOS::Model::Generator.module.save!
  module_id = mod.id.as(String)

  control_system = PlaceOS::Model::Generator.control_system
  control_system.modules = [module_id]
  control_system.save!

  wait_for_module_lookups(control_system.id.as(String), {"#{mod.resolved_name}/1" => module_id})
  {control_system, mod}
end

# Binds to the websocket API
# Yields API websocket, and a control system + module
# Cleans up the websocket and models
def test_websocket_api(base, headers, &)
  control_system, mod = websocket_spec_system
  updates = [] of PlaceOS::Api::WebSocket::Session::Response

  on_message = ->(message : String) {
    updates << PlaceOS::Api::WebSocket::Session::Response.from_json message
  }

  bind(base, headers, on_message) do |ws|
    # `updates` is exposed so tests can gate on messages arriving (vs fixed sleeps).
    # Blocks that don't need it can simply take fewer params.
    yield ({ws, control_system, mod, updates})
  end

  # Clean up.
  control_system.destroy
  mod.destroy

  {updates, control_system, mod}
end

def test_websocket_exec(base, headers, &)
  control_system, mod = websocket_spec_system
  module_slug = mod.id.as(String)

  PlaceOS::Driver::RedisStorage.with_redis do |redis|
    meta = PlaceOS::Driver::DriverModel::Metadata.new({
      "nugget"    => {} of String => JSON::Any,
      "function2" => {"arg1" => JSON.parse(%({"type":"integer"}))},
      "function3" => {"arg1" => JSON.parse(%({"type":"integer"})), "arg2" => JSON.parse(%({"type":"integer","default":200}))},
    }, ["Functoids"])

    redis.set("interface/#{module_slug}", meta.to_json)
  end

  updates = [] of PlaceOS::Api::WebSocket::Session::Response

  on_message = ->(message : String) {
    updates << PlaceOS::Api::WebSocket::Session::Response.from_json message
  }

  bind(base, headers, on_message) do |ws|
    yield ({ws, control_system, mod})
  end

  # Clean up.
  control_system.destroy
  mod.destroy

  {updates, control_system, mod}
end

# Deliberately use reverse lexical order and a nonmatching module first to
# distinguish interface index from name index and Redis hash iteration order.
def test_websocket_interfaces(headers, protected_module : Bool = false, &)
  modules = ["Interface::Sensor", protected_module ? "_Sensor" : "ZSensor", "ASensor"].map do |name|
    mod = PlaceOS::Model::Generator.module
    mod.custom_name = name
    mod.save!
  end
  system = PlaceOS::Model::Generator.control_system
  system.modules = modules.map(&.id.as(String))
  system.save!
  lookups = modules.to_h { |mod| {"#{mod.resolved_name}/1", mod.id.as(String)} }
  wait_for_module_lookups(system.id.as(String), lookups)

  PlaceOS::Driver::RedisStorage.with_redis do |redis|
    modules[1..2].each do |mod|
      metadata = PlaceOS::Driver::DriverModel::Metadata.new(
        interface: {"read" => {} of String => JSON::Any, "restricted" => {} of String => JSON::Any},
        implements: ["Interface::Sensor"],
        security: {"administrator" => ["restricted"]},
      )
      redis.set("interface/#{mod.id}", metadata.to_json)
    end
  end
  updates = [] of PlaceOS::Api::WebSocket::Session::Response
  on_message = ->(message : String) {
    updates << PlaceOS::Api::WebSocket::Session::Response.from_json(message)
  }
  bind(PlaceOS::Api::Systems.base_route, headers, on_message) do |ws|
    yield ws, system, modules, updates
  end
ensure
  system.try(&.destroy)
  modules.try(&.each(&.destroy))
end

def interface_request(system, command : PlaceOS::Api::WebSocket::Session::Request::Command,
                      module_name = "Interface::Sensor", index = 1, name = "read", interface = true, args : Array(JSON::Any)? = nil)
  PlaceOS::Api::WebSocket::Session::Request.new(
    id: 123_i64,
    system_id: system.id.as(String),
    module_name: module_name,
    command: command,
    name: name,
    index: index,
    interface: interface,
    args: args,
  )
end
