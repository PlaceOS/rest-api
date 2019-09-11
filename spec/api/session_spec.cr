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

      describe "websocket API" do
        pending "exec"
        describe "bind" do
          it "receives updates" do
            # Create a System
            control_system = Model::Generator.control_system.save!

            # Create a Module
            mod = Model::Generator.module(control_system: control_system).save!

            # Random request id
            request_id = RANDOM.hex(7)

            # Create a storage proxy
            driver_proxy = EngineDriver::Storage.new mod.id.as(String)

            status_name = "nugget"

            updates = [] of Session::Response

            on_message = ->(message : String) {
              updates << Session::Response.from_json message
            }

            bind(base, authorization_header, on_message) do |ws|
              ws.send Session::Message.new(
                request_id: request_id,
                sys_id: control_system.id.as(String),
                module_name: mod.name.as(String),
                name: status_name,
                command: Session::Command::Bind,
              ).to_json

              sleep 2
              driver_proxy[status_name] = 1
              sleep 2
              driver_proxy[status_name] = 2
              sleep 2
            end

            updates.should_not be_empty

            expected_meta = {
              sys:   control_system.id,
              mod:   mod.name,
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

            # Clean up.
            control_system.destroy
            mod.destroy
          end
        end

        pending "unbind"
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
