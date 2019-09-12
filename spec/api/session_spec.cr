require "../helper"

require "engine-driver/storage"

module Engine::API
  authenticated_user, authorization_header = authentication
  base = Systems::NAMESPACE[0]

  describe Session do
    with_server do
      describe "/bind" do
        it "opens a websocket session" do
          bind(base, authorization_header) do |ws|
            ws.closed?.should be_false
          end
        end
      end

      it "does some stuff" do
        in_callback = false
        sub_passed = nil
        message_passed = nil
        channel = Channel(Nil).new
        redis = EngineDriver::Storage.redis_pool

        # Ensure keys don't already exist
        sys_lookup = EngineDriver::Storage.new("sys-123", "system")
        lookup_key = "Display\x021"
        sys_lookup.delete lookup_key
        storage = EngineDriver::Storage.new("mod-1234")
        storage.delete("power")

        subs = EngineDriver::Subscriptions.new
        subscription = subs.subscribe "sys-123", "Display", 1, :power do |sub, message|
          sub_passed = sub
          message_passed = message
          in_callback = true
          channel.close
        end

        # Subscription should not exist yet - i.e. no lookup
        subscription.module_id.should eq(nil)

        # Create the lookup and signal the change
        sys_lookup[lookup_key] = "mod-1234"
        redis.publish "lookup-change", "sys-123"

        sleep 0.05

        # Update the status
        storage["power"] = true
        channel.receive?

        subscription.module_id.should eq("mod-1234")
        in_callback.should eq(true)
        message_passed.should eq("true")
        sub_passed.should eq(subscription)

        storage.delete("power")
        sys_lookup.delete lookup_key
        subs.terminate
      end

      describe "websocket API" do
        pending "exec"
        describe "bind" do
          it "receives updates" do
            # Status to bind
            status_name = "nugget"

            results = test_websocket_api(base, authorization_header) do |ws, control_system, mod|
              ws.send Session::Request.new(
                id: RANDOM.hex(7),
                sys_id: control_system.id.as(String),
                module_name: mod.custom_name.as(String),
                name: status_name,
                command: Session::Request::Command::Bind,
              ).to_json
              sleep 2

              # Create a storage proxy
              driver_proxy = EngineDriver::Storage.new mod.id.as(String)
              driver_proxy[status_name] = 1
              sleep 1
              driver_proxy[status_name] = 2
              sleep 5
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
            updates.all? { |v| v.meta == expected_meta }.should be_true
            # Check all messages received
            updates.size.should eq 3
            # Check for status variable updates
            updates[1..2].map(&.value.not_nil!.as_i).should eq [1, 2]
          end
        end

        it "unbind" do
          # Status to bind
          status_name = "nugget"

          results = test_websocket_api(base, authorization_header) do |ws, control_system, mod|
            request = {
              id:          RANDOM.hex(7),
              sys_id:      control_system.id.as(String),
              module_name: mod.custom_name.as(String),
              name:        status_name,
              command:     Session::Request::Command::Bind,
            }
            ws.send Session::Request.new(**request).to_json
            ws.send Session::Request.new(**request.merge({command: Session::Request::Command::Bind})).to_json
          end

          updates, control_system, mod = results

          expected_meta = {
            sys:   control_system.id,
            mod:   mod.custom_name,
            index: 1,
            name:  status_name,
          }

          # Check all messages received
          updates.size.should eq 2
          # Check all responses correct metadata
          updates.all? { |v| v.meta == expected_meta }.should be_true
          # Check for successful bind response
          updates.shift.type.should eq Session::Response::Type::Success
          # Check for successful unbind response
          updates.shift.type.should eq Session::Response::Type::Success
        end
        pending "debug"
        pending "ignore"
      end
    end
  end
end

# Generate a controller context for testing a websocket
#
def websocket_context(path)
  context(
    method: "GET",
    path: path,
    headers: HTTP::Headers{
      "Connection" => "Upgrade",
      "Upgrade"    => "websocket",
      "Origin"     => "localhost",
    }
  )
end

# Binds to the system websocket endpoint
#
def bind(base, auth, on_message : Proc(String, _) = ->(_msg : String) {})
  bearer = auth["Authorization"].split(' ').last
  path = "#{base}bind?bearer_token=#{bearer}"

  # Create a websocket connection, then run the session
  socket = HTTP::WebSocket.new("localhost", path, 6000)
  socket.on_message &on_message

  spawn { socket.run }
  yield socket
  socket.close
end

# Binds to the websocket API
# Yields API websocket, and a control system + module
# Cleans up the websocket and models
def test_websocket_api(base, authorization_header)
  # Create a System
  control_system = Engine::Model::Generator.control_system.save!

  # Create a Module
  mod = Engine::Model::Generator.module(control_system: control_system).save!
  updates = [] of Engine::API::Session::Response

  on_message = ->(message : String) {
    updates << Engine::API::Session::Response.from_json message
  }

  # Set metadata in redis to allow binding to module
  sys_lookup = EngineDriver::Storage.new(control_system.id.as(String), "system")
  lookup_key = "#{mod.custom_name}\x021"
  sys_lookup[lookup_key] = mod.id.as(String)

  driver_proxy = EngineDriver::Storage.new mod.id.as(String)
  driver_proxy["nugget"] = 100

  bind(base, authorization_header, on_message) do |ws|
    yield ({ws, control_system, mod})
  end

  # Clean up.
  control_system.destroy
  mod.destroy

  {updates, control_system, mod}
end
