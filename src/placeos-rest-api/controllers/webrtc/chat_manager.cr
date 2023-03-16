require "http"
require "./kick_reason"

module PlaceOS::Api
  # use a manager so the we can free the request context objects
  class ChatManager
    Log = ::Log.for(self)

    def initialize(@ice_config)
      # grab the existing `PlaceOS::Driver::Subscriptions` instance
      subscriber = PlaceOS::Api::WebSocket::Session.subscriptions.@subscriber
      subscriber.channel("internal/chat/forward_signal") do |_, payload|
        signal = SessionSignal.from_json(payload)
        perform_forwarded_signal(signal)
      end
      subscriber.channel("internal/chat/kick_user") do |_, payload|
        user_id, reason = Tuple(String, String).from_json(payload)
        perform_kick_user(user_id, reason)
      end
      subscriber.channel("internal/chat/transfer_user") do |_, payload|
        user_id, session_id, connection_details = Tuple(String, String?, String?).from_json(payload)
        perform_transfer(user_id, session_id, connection_details)
      end

      spawn { ping_sockets }
    end

    # =================================
    # Websocket Ping / ensure connected
    # =================================

    protected def ping_sockets
      loop do
        sleep 30

        # ping the sockets to ensure connectivity
        begin
          connections = sockets.dup
          id = "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}"
          connections.each do |websocket, session|
            perform_ping(id, websocket, session) rescue Exception
          end
        rescue
        end
      end
    end

    protected def perform_ping(id, websocket, session)
      send_signal(websocket, SessionSignal.new(
        id: id,
        type: :ping,
        session_id: session.session_id,
        user_id: "SERVER::DATA",
        to_user: session.user_id,
        value: "{}"
      ))
    rescue
    end

    # =================================
    # Various helpers
    # =================================

    protected def redis_publish(path : String, payload)
      ::PlaceOS::Driver::RedisStorage.with_redis &.publish(path, payload.to_json)
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

    def member_list(session_id : String) : Array(String)
      CallDetails::SESSIONS.user_list(session_id)
    end

    # =================================
    # Connection management
    # =================================

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
        signal.place_auth_id = auth_id

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

          # signals routed to the system id that represents the application managing the chat
          redis_publish("placeos/#{auth_id}/chat/user/left", {
            connect_details.session_id => connect_details.user_id,
          })
        end
      end
    end

    def remove_from_call(connect_details : SessionSignal)
      session_id = connect_details.session_id

      if call = calls[session_id]?
        # inform the call peers that the user is gone
        call.remove connect_details.user_id
        # cleanup empty sessions
        calls.delete(session_id) if call.peers.empty?
      end

      # forward the leave signal to all the members of the call
      connect_details.type = :leave
      CallDetails::SESSIONS.user_list(session_id).each do |user_id|
        connect_details.to_user = user_id
        redis_publish("placeos/internal/chat/forward_signal", connect_details)
      end
    end

    def on_join_signal(websocket, signal, auth_id) : Nil
      call = calls[signal.session_id]? || create_new_call(signal)

      # check the current user can join the call (prevent spoofing)
      # TODO:: look into this now the service is clustered
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
      call.add(signal.user_id, websocket)
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

      # signals routed to the system id that represents the application managing the chat
      redis_publish("placeos/#{signal.place_auth_id}/chat/user/joined", {
        signal.session_id => signal.user_id,
      })
    end

    # ================================
    # Forward signal
    # ================================

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

        redis_publish("placeos/internal/chat/forward_signal", signal)
      end
    end

    # all security checks have occured at this point, forward the message
    # if the user is connected to this server
    protected def perform_forwarded_signal(signal)
      if call = calls[signal.session_id]?
        if to_user = call.peers[signal.to_user]?
          send_signal(to_user, signal)
        end
      end
    end

    # ================================
    # Kick User / User exited
    # ================================

    # the user has exited chat
    def end_call(user_id : String, auth_id : String)
      # signal the user exited
      redis_publish("placeos/#{auth_id}/chat/user/exited", {
        user_id: user_id,
      })

      # find the users websocket
      spawn do
        sleep 1
        redis_publish("placeos/internal/chat/kick_user", {user_id, "call ended"})
      end
    end

    def kick_user(auth_id : String, user_id : String, session_id : String, details : KickReason)
      # find the users websocket
      redis_publish("placeos/internal/chat/kick_user", {user_id, details.reason})

      redis_publish("placeos/#{auth_id}/chat/user/exited", {
        user_id: user_id,
      })
    end

    def perform_kick_user(user_id, reason)
      # find the users websocket
      websocket = user_lookup[user_id]?
      return unless websocket

      connect_details = sockets[websocket]?
      return unless connect_details

      # send the kicked user a leave signal
      send_signal(websocket, SessionSignal.new(
        id: "SIGNAL::#{Time.utc.to_unix_ms}+#{Random::Secure.hex(6)}",
        type: :leave,
        session_id: connect_details.session_id,
        user_id: user_id,
        to_user: user_id,
        value: KickReason.new(reason).to_json
      ))

      websocket.close
    end

    # ================================
    # Transfer user
    # ================================

    enum TransferResult
      NoConnection
      NoSession # not currently used
      SignalSent
    end

    # transfer a user to a new chat room
    def transfer(user_id : String, session_id : String? = nil, payload : String? = nil) : TransferResult
      current_session_id = CallDetails::SESSIONS.lookup_session(user_id)
      return TransferResult::NoConnection unless current_session_id

      redis_publish("placeos/internal/chat/transfer_user", {user_id, session_id, payload})
      TransferResult::SignalSent
    end

    def perform_transfer(user_id : String, session_id : String? = nil, payload : String? = nil)
      # find the users websocket
      websocket = user_lookup[user_id]?
      return unless websocket

      connect_details = sockets[websocket]?
      return unless connect_details

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
    end
  end
end
