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
          ws.send Session::Request.new(**request.merge({command: Session::Request::Command::Bind})).to_json
          wait_for_updates(updates, 2)
        end

        updates, control_system, mod = results
        expected_meta = {sys: control_system.id, mod: mod.custom_name, index: 1, name: status_name}
        # Check all messages received
        updates.size.should eq 2
        # Check all responses correct metadata
        updates.all? { |v| v.metadata == expected_meta }.should be_true
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
