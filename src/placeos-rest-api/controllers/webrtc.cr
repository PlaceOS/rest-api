require "base64"
require "./application"
require "./webrtc/*"

module PlaceOS::Api
  class WebRTC < Application
    base "/api/engine/v2/webrtc/"

    # skip authentication for guest_entry and room details
    skip_action :authorize!, only: [:guest_entry, :public_room]
    skip_action :set_user_id, only: [:guest_entry, :public_room]

    # allow guest access to the signalling route
    before_action :can_read_guest, only: [:signaller, guest_exit]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:guest_entry, :public_room])]
    def find_current_control_system(
      @[AC::Param::Info(description: "either a system id or a unique permalink", example: "sys-12345")]
      system_id : String
    )
      system = if system_id.starts_with? "sys-"
                 Model::ControlSystem.find!(system_id, runopts: {"read_mode" => "majority"})
               else
                 res = Model::ControlSystem.where(code: system_id).first?
                 raise Error::NotFound.new("could not find room #{system_id}") unless res
                 res
               end

      # ensure the system is public
      raise Error::NotFound.new("could not find room #{system_id}") unless system.public

      Log.context.set(control_system_id: system.id.not_nil!)
      @current_control_system = system
    end

    getter! current_control_system : Model::ControlSystem

    # Response helpers
    ###############################################################################################

    struct CaptchaResponse
      include JSON::Serializable

      property success : Bool
    end

    class PlaceOS::Api::Error
      class RecaptchaFailed < Error
      end

      class GuestAccessDisabled < Error
      end
    end

    ###############################################################################################

    # 401 if recaptcha fails
    @[AC::Route::Exception(Error::RecaptchaFailed, status_code: HTTP::Status::UNAUTHORIZED)]
    def recaptcha_failed(error) : CommonError
      Log.debug { error.message }
      CommonError.new(error, false)
    end

    JWT_SECRET = ENV["JWT_SECRET"]?.try { |k| Base64.decode_string(k) }

    # this route provides a guest access to an anonymous chat room
    @[AC::Route::POST("/guest_entry/:system_id", body: guest)]
    def guest_entry(
      guest : GuestParticipant,
      @[AC::Param::Info(description: "either a system id or a unique permalink", example: "sys-12345")]
      system_id : String
    ) : Nil
      jwt_secret = JWT_SECRET
      raise Error::GuestAccessDisabled.new("guest access not enabled") unless jwt_secret

      # captcha, name, phone, type, chat_to_user_id, room_id, guest_chat_id (user_id), session_id
      authority = current_authority.not_nil!
      if recaptcha_secret = authority.internals["recaptcha_secret"]?.try(&.as_s)
        HTTP::Client.new("www.google.com", tls: true) do |client|
          client.connect_timeout = 2

          begin
            captresp = client.post("/recaptcha/api/siteverify?secret=#{recaptcha_secret}&response=#{guest.captcha}")
            if captresp.success?
              result = CaptchaResponse.from_json(captresp.body)
              raise Error::RecaptchaFailed.new("recaptcha rejected") unless result.success
            else
              raise Error::RecaptchaFailed.new("error verifying recaptcha response")
            end
          rescue error
            # We don't want chat to be out of action if google is down, so we'll continue
            Log.error(exception: error) { "recaptcha failed" }
          end
        end
      else
        raise Error::RecaptchaFailed.new("recaptcha not configured") unless authority.internals["recaptcha_skip"]? == true
      end

      expires = 12.hours.from_now
      payload = {
        iss:   "POS",
        iat:   1.minute.ago.to_unix,
        exp:   expires.to_unix,
        jti:   UUID.random.to_s,
        aud:   authority.domain,
        scope: ["guest"],
        sub:   "guest-#{UUID.random}",
        u:     {
          n: guest.name,
          e: guest.email || "#{guest.phone}@phone" || "#{guest.name}@unknown",
          p: 0,
          r: [guest.user_id, system_id],
        },
      }

      jwt = JWT.encode(payload, jwt_secret, JWT::Algorithm::RS256)
      response.cookies << HTTP::Cookie.new(
        name: "bearer_token",
        value: jwt,
        path: "/api/engine/v2/webrtc",
        expires: expires,
        secure: true,
        http_only: true,
        samesite: :strict
      )

      # check if there is alternative room handling the chat members
      system = current_control_system
      chat_system = system.id
      system.zones.each do |zone_id|
        meta = Model::Metadata.build_metadata(zone_id, "bindings")
        if payload = meta["bindings"]?.try(&.details)
          if chat_room = payload["chat_room"]?.try(&.as_s?)
            chat_system = chat_room
            break
          end
        end
      end

      # signals routed to the system id that represents the application managing the chat
      ::PlaceOS::Driver::RedisStorage.with_redis &.publish("placeos/#{authority.id}/chat/#{chat_system}/guest/entry", {
        system.id.not_nil! => guest,
      }.to_json)
    end

    @[AC::Route::POST("/guest/exit")]
    def guest_exit : Nil
      response.cookies << HTTP::Cookie.new(
        name: "bearer_token",
        value: "",
        path: "/api/engine/v2/webrtc",
        expires: Time.utc,
        secure: true,
        http_only: true,
        samesite: :strict
      )

      token = user_token
      if token.scope.first == "guest" && token.id.starts_with?("guest-")
        user_id = token.user.roles.first
        authority = current_authority.not_nil!
        auth_id = authority.id.as(String)
        self.class.end_call(user_id, auth_id)
      end
    end

    def self.end_call(user_id, auth_id)
      spawn do
        # give the browser a moment to update its cookie
        # we don't want them reconnecting
        sleep 1
        Log.info { "signalling end call for #{user_id} on #{auth_id}" }
        MANAGER.end_call(user_id, auth_id)
      end
    end

    # Call ended for user
    # send a leave signal to the user from the user (no value)
    @[AC::Route::POST("/kick/:user_id/:session_id", body: details)]
    def kick_user(user_id : String, session_id : String, details : KickReason) : Nil
      MANAGER.kick_user(user_id, session_id, details)
    end

    # Obtain a list of the connected users in chat session provided
    @[AC::Route::GET("/members/:session_id")]
    def members(session_id : String) : Array(String)
      MANAGER.member_list(session_id)
    end

    # for authorised users to move people from one chat to another
    @[AC::Route::POST("/transfer/:user_id/?:session_id", body: body, status: {
      Nil  => HTTP::Status::OK,
      Bool => HTTP::Status::PRECONDITION_REQUIRED,
    })]
    def transfer_guest(
      user_id : String,
      session_id : String? = nil,
      body : JSON::Any? = nil
    ) : Nil | Bool
      result = MANAGER.transfer(user_id, session_id, body.try &.to_json)
      case result
      in .signal_sent?
        nil
      in .no_session?
        true
      in .no_connection?
        false
      end
    end

    struct RoomDetails
      include JSON::Serializable

      getter system : Model::ControlSystem
      getter metadata : Hash(String, PlaceOS::Model::Metadata::Interface)

      def initialize(@system, @metadata)
      end
    end

    # this route provides a guest access to an anonymous chat room
    @[AC::Route::GET("/room/:system_id")]
    def public_room(
      @[AC::Param::Info(description: "either a system id or a unique permalink", example: "sys-12345")]
      system_id : String
    ) : RoomDetails
      system = current_control_system
      meta = Model::Metadata.build_metadata(system.id.not_nil!, nil)
      RoomDetails.new(system, meta)
    end

    ICE_CONFIG = {} of String => String
    MANAGER    = ChatManager.new(ICE_CONFIG)

    # WebRTC signaller endpoint, managing call participants
    @[AC::Route::WebSocket("/signaller")]
    def signaller(websocket) : Nil
      Log.trace { {request_id: request_id, frame: "OPEN"} }

      authority = current_authority.not_nil!
      auth_id = authority.id.as(String)

      # https://developer.mozilla.org/en-US/docs/Web/API/RTCIceServer
      ICE_CONFIG[auth_id] = authority.internals["webrtc_ice"]?.try(&.to_json) || WEBRTC_DEFAULT_ICE_CONFIG

      MANAGER.handle_session(websocket, request_id, user_token.id, auth_id)
    end
  end
end
