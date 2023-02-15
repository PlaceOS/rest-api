module PlaceOS::Api
  # TODO:: this will live in redis once testing is complete
  class CallDetails
    include JSON::Serializable

    getter id : String
    getter peers : Hash(String, HTTP::WebSocket)

    @[JSON::Field(converter: Time::EpochConverter)]
    getter created_at : Time

    @[JSON::Field(converter: Time::EpochConverter)]
    property updated_at : Time

    def initialize(@id : String)
      @peers = {} of String => HTTP::WebSocket
      @updated_at = @created_at = Time.utc
    end
  end

  # use a manager so the we can free the request context objects
  class ChatManager
    Log = ::Log.for(self)

    def initialize(@ice_config)
    end

    # authority_id => config string
    private getter ice_config : Hash(String, String)
    private getter calls = {} of String => CallDetails
    private getter sockets = {} of HTTP::WebSocket => SessionSignal
    private getter user_lookup = {} of String => HTTP::WebSocket

    def handle_session(websocket, request_id, user_id, auth_id)
      websocket.on_message do |message|
        Log.context.set(request_id: request_id, user_id: user_id)
        Log.trace { {frame: "TEXT", text: message} }

        signal = SessionSignal.from_json(message)
        signal.place_user_id = user_id

        case signal.type
        when .join?
          on_join_signal(websocket, signal, auth_id)
        when .offer?, .answer?, .candidate?, .leave?
          forward_signal(websocket, signal)
        else
          Log.warn { "user #{user_id} sent unsupported signal #{signal.type}" }
        end

        if call = calls[signal.session_id]?
          call.updated_at = Time.utc
        end
      end

      websocket.on_close do |_|
        Log.trace { {request_id: request_id, frame: "CLOSE"} }

        if connect_details = sockets.delete websocket
          user_lookup.delete connect_details.user_id
          remove_from_call(connect_details)
        end
      end
    end

    def remove_from_call(connect_details : SessionSignal)
      call = calls[connect_details.session_id]?
      return unless call

      # inform the call peers that the user is gone
      call.peers.delete connect_details.user_id
      call.updated_at = Time.utc

      connect_details.type = :leave
      call.peers.each_value do |ws|
        send_signal(ws, connect_details)
      end

      # cleanup empty sessions
      calls.delete(connect_details.session_id) if call.peers.empty?
    end

    def create_new_call(signal) : CallDetails
      calls[signal.session_id] = CallDetails.new(signal.session_id)
    end

    def send_signal(websocket, signal)
      Log.trace { "Sending signal #{signal.type} to #{signal.session_id}" }
      websocket.send(signal.to_json)
    rescue
      # we'll ignore websocket send failures, the user will be cleaned up
    end

    def on_join_signal(websocket, signal, auth_id) : Nil
      call = calls[signal.session_id]? || create_new_call(signal)

      # check the current user can join the call (prevent spoofing)
      if existing_peer_ws = call.peers[signal.user_id]?
        if existing_user = sockets[existing_peer_ws]?
          if existing_user.place_user_id != signal.place_user_id
            Log.warn { "possible hacking attempt by #{signal.place_user_id}, attempting to spoof #{existing_user.place_user_id}" }
            websocket.close
            return
          end
        end
      end

      # check if the user is already in another call and remove them
      if existing_user = sockets[websocket]?
        remove_from_call existing_user
      end

      # add the user to the new call
      user_lookup[signal.user_id] = websocket
      call.peers[signal.user_id] = websocket
      sockets[websocket] = signal

      # Return RTC configuration details
      send_signal(websocket, SessionSignal.new(
        id: "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}",
        type: :join,
        session_id: signal.session_id,
        user_id: "SERVER::DATA",
        to_user: signal.user_id,
        value: ice_config[auth_id]
      ))

      # Send participant list
      send_signal(websocket, SessionSignal.new(
        id: "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}",
        type: :participant_list,
        session_id: signal.session_id,
        user_id: "SERVER::DATA",
        to_user: signal.user_id,
        value: call.peers.keys.to_json
      ))
    end

    def forward_signal(websocket, signal) : Nil
      if call = calls[signal.session_id]?
        # check the current user is in the call
        if existing_peer_ws = call.peers[signal.user_id]?
          if existing_user = sockets[existing_peer_ws]?
            if existing_user.place_user_id != signal.place_user_id
              Log.warn { "possible hacking attempt by #{signal.place_user_id}, attempting to spoof #{existing_user.place_user_id}" }
              websocket.close
              return
            end
          end
        else
          Log.warn { "possible hacking attempt by #{signal.place_user_id}, attempting to signal a call they are not in" }
          websocket.close
          return
        end

        if to_user = call.peers[signal.to_user]?
          send_signal(to_user, signal)
        end
      end
    end

    enum TransferResult
      NoConnection
      NoSession
      SignalSent
    end

    # the user has exited chat
    def end_call(user_id : String)
      # find the users websocket
      websocket = user_lookup[user_id]?
      websocket.try &.close
    end

    def kick_user(user_id : String, session_id : String)
      # find the users websocket
      websocket = user_lookup[user_id]?
      return unless websocket

      connect_details = sockets[websocket]?
      return unless connect_details

      # remove the user from the current call
      remove_from_call(connect_details)

      # send the kicked user a leave signal
      send_signal(websocket, SessionSignal.new(
        id: "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}",
        type: :leave,
        session_id: session_id,
        user_id: user_id,
        to_user: user_id,
        value: nil
      ))
    end

    # transfer a user to a new chat room
    def transfer(user_id : String, session_id : String? = nil, payload : String? = nil) : TransferResult
      # find the users websocket
      websocket = user_lookup[user_id]?
      return TransferResult::NoConnection unless websocket

      connect_details = sockets[websocket]?
      return TransferResult::NoSession unless connect_details

      # remove the user from the current call
      remove_from_call(connect_details) if session_id && session_id != connect_details.session_id

      # send the user a Transfer signal
      send_signal(websocket, SessionSignal.new(
        id: "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}",
        type: :transfer,
        session_id: session_id || connect_details.session_id,
        user_id: "SERVER::DATA",
        to_user: user_id,
        value: payload
      ))
      TransferResult::SignalSent
    end
  end
end
