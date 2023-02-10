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
    before_action :can_read_guest, only: [:signaller]

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

      # TODO:: ensure the system is valid and exists
      # the system id that defines the name and rules for a collection of chats
      # note, this is not a chat, it represents a collection of chats

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

      ::PlaceOS::Driver::RedisStorage.with_redis &.publish("placeos/#{authority.domain}/guest/entry", {
        system_id => guest,
      }.to_json)
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

    # * create a permalink entry for systems
    # * system public flag for grabbing metadata
    # *

    # this route provides a guest access to an anonymous chat room
    @[AC::Route::GET("/room/:system_id")]
    def public_room(
      @[AC::Param::Info(description: "either a system id or a unique permalink", example: "sys-12345")]
      system_id : String
    ) : RoomDetails
      # TODO:: check the system is public
      system = Model::ControlSystem.find!(system_id, runopts: {"read_mode" => "majority"})
      meta = Model::Metadata.build_metadata(system_id, nil)
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
