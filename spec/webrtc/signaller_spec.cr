require "../helper"

module PlaceOS::Api
  describe WebRTC do
    it "opens a websocket session" do
      updates = [] of SessionSignal

      on_message = ->(message : String) {
        updates << SessionSignal.from_json message
      }

      session_id = UUID.random.to_s
      user_id = UUID.random.to_s
      transfer = {login: "user", pass: "pass"}.to_json

      signaller(on_message) do |ws|
        ws.closed?.should be_false
        ws.send(SessionSignal.new(
          id: "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}",
          type: :join,
          session_id: session_id,
          user_id: user_id,
          to_user: "server",
          value: nil
        ).to_json)
        sleep 0.5
        updates.size.should eq 2

        sessions = CallDetails::SESSIONS
        sessions.user_list(session_id).should eq [user_id]
        sessions.lookup_session(user_id).should eq session_id

        # test transfer signal
        # WebRTC::MANAGER.transfer(user_id, session_id, transfer)
        client.post(
          path: "/api/engine/v2/webrtc/transfer/#{user_id}/#{session_id}",
          body: transfer,
          headers: Spec::Authentication.headers,
        )
        sleep 0.5
        updates.size.should eq 3
        updates[-1].value.should eq transfer

        # test kick user
        # MANAGER.kick_user(auth_id, user_id, session_id, details)
        client.post(
          path: "/api/engine/v2/webrtc/kick/#{user_id}/#{session_id}",
          body: {reason: "bad user"}.to_json,
          headers: Spec::Authentication.headers,
        )
        sleep 0.5
        updates.size.should eq 4
        ws.closed?.should be_true
      end
    end
  end
end

def signaller(on_message : Proc(String, _) = ->(_msg : String) {}, &)
  host = "localhost"
  bearer = PlaceOS::Api::Spec::Authentication.headers["Authorization"].split(' ').last
  path = File.join(PlaceOS::Api::WebRTC.base_route, "signaller?bearer_token=#{bearer}")

  # Create a websocket connection, then run the session
  socket = client.establish_ws(path, headers: HTTP::Headers{"Host" => host})

  socket.on_message &on_message

  spawn(same_thread: true) { socket.run }

  yield socket

  socket.close
end
