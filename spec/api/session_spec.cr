require "../helper"

module Engine::API
  authenticated_user, authorization_header = authentication
  base = Systems::NAMESPACE[0]

  describe Session do
    with_server do
      describe "commands" do
        it "exec" do
          #  message = Session::Message.new(
          #    id: ,
          #    sys_id: ,
          #    module_name: ,
          #    command: ,
          #    name: ,
          #  )
          #  bind do |s|
          #    s.send(Session::Message.new(
          #    ))
          #  end
        end
        it "bind" do
        end
        it "unbind" do
        end
        it "debug" do
        end
        it "ignore" do
        end
      end
    end
  end
end

# Binds to the system websocket endpoint
#
def bind
  bearer = authorization_header["Authorization"].split(' ').last
  path = "#{base}/bind?access_token=#{bearer}"
  # Create a websocket connection, then run the session
  socket = HTTP::WebSocket.new("localhost", path, 6000)
  spawn { socket.run }

  yield socket

  socket.close
end
