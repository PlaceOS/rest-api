require "base64"
require "jwt"
require "placeos-driver/storage"
require "placeos-driver/proxy/system"
require "placeos-driver/proxy/remote_driver"

require "./application"

module PlaceOS::Api
  class PublicEvents < Application
    include Utils::CoreHelper

    base "/api/engine/v2/public_events/"

    # guest_token is fully unauthenticated — reCAPTCHA is the only gate.
    skip_action :authorize!, only: [:guest_token]
    skip_action :set_user_id, only: [:guest_token]

    # Regular authenticated users AND guest JWTs may call index / register.
    before_action :can_read_guest, only: [:index, :register]

    ##########################################################################
    # Before filters
    ##########################################################################

    # Resolves the target ControlSystem from either a system-id or a permalink
    # (code).  Raises 404 if the system does not exist or is not marked public.
    @[AC::Route::Filter(:before_action, only: [:guest_token, :index, :register])]
    def find_current_control_system(
      @[AC::Param::Info(description: "a system id or unique permalink", example: "sys-12345")]
      system_id : String,
    )
      system = if system_id.starts_with?("sys-")
                 ::PlaceOS::Model::ControlSystem.find!(system_id)
               else
                 res = ::PlaceOS::Model::ControlSystem.where(code: system_id).first?
                 raise Error::NotFound.new("could not find system #{system_id}") unless res
                 res
               end

      raise Error::NotFound.new("could not find system #{system_id}") unless system.public

      Log.context.set(control_system_id: system_id)
      @current_control_system = system
    end

    getter! current_control_system : ::PlaceOS::Model::ControlSystem

    ##########################################################################
    # Request / response structs
    ##########################################################################

    struct CaptchaResponse
      include JSON::Serializable
      property? success : Bool
    end

    struct TokenRequest
      include JSON::Serializable
      getter captcha : String
      getter name : String
      getter email : String
    end

    struct RegistrationRequest
      include JSON::Serializable
      getter event_id : String
      getter name : String
      getter email : String
    end

    ##########################################################################
    # Constants
    ##########################################################################

    JWT_SECRET  = ENV["JWT_SECRET"]?.try { |k| Base64.decode_string(k) }
    MODULE_NAME = "PublicEvents"

    ##########################################################################
    # Routes
    ##########################################################################

    # Issues a short-lived guest JWT after verifying the reCAPTCHA challenge.
    #
    # The resulting token is scoped to the requested public system and grants:
    # - read access to the cached `:public_events` driver status
    # - the ability to call `register_attendee` via the `/register` route
    #
    # Mirrors the WebRTC `guest_entry` flow:
    # - authority.internals["recaptcha_secret"] → live Google verification
    # - authority.internals["recaptcha_skip"] = true → skip (dev / test only)
    @[AC::Route::POST("/guest_token/:system_id", body: :params)]
    def guest_token(
      system_id : String,
      params : TokenRequest,
    ) : String
      jwt_secret = JWT_SECRET
      raise Error::GuestAccessDisabled.new("guest access not enabled") unless jwt_secret

      authority = current_authority.as(::PlaceOS::Model::Authority)

      if recaptcha_secret = authority.internals["recaptcha_secret"]?.try(&.as_s)
        HTTP::Client.new("www.google.com", tls: true) do |http|
          http.connect_timeout = 2.seconds
          begin
            resp = http.post("/recaptcha/api/siteverify?secret=#{recaptcha_secret}&response=#{params.captcha}")
            if resp.success?
              result = CaptchaResponse.from_json(resp.body)
              raise Error::RecaptchaFailed.new("recaptcha rejected") unless result.success?
            else
              raise Error::RecaptchaFailed.new("error verifying recaptcha response")
            end
          rescue error : Error::RecaptchaFailed
            raise error
          rescue error
            # Do not block the user if Google is temporarily unreachable.
            Log.error(exception: error) { "recaptcha verification failed" }
          end
        end
      else
        raise Error::RecaptchaFailed.new("recaptcha not configured") unless authority.internals["recaptcha_skip"]? == true
      end

      system = current_control_system
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
          n: params.name,
          e: params.email,
          p: 0,
          r: [system_id],
        },
      }

      jwt = JWT.encode(payload, jwt_secret, JWT::Algorithm::RS256)

      response.cookies << HTTP::Cookie.new(
        name: "bearer_token",
        value: jwt,
        path: "/api/engine/v2/public_events",
        expires: expires,
        secure: true,
        http_only: true,
        samesite: :strict,
      )

      jwt
    end

    # Returns the cached list of public events for the given system.
    #
    # Reads the `:public_events` status key directly from Redis — no live
    # driver round-trip is made.  The response is sourced from the cache that
    # the PublicEvents driver maintains via its Bookings subscription.
    #
    # Guest JWTs are accepted provided the system id appears in their roles.
    @[AC::Route::GET("/:system_id/events")]
    def index(system_id : String) : Array(JSON::Any)
      if user_token.guest_scope?
        raise Error::Forbidden.new unless user_token.user.roles.includes?(current_control_system.id)
      end

      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: system_id,
        module_name: MODULE_NAME,
        index: 1,
      )

      return [] of JSON::Any unless module_id

      storage = Driver::RedisStorage.new(module_id)
      raw = storage["public_events"]?
      return [] of JSON::Any unless raw

      Array(JSON::Any).from_json(raw)
    rescue e : JSON::ParseException
      Log.warn(exception: e) { "failed to parse public_events cache for #{current_control_system.id}" }
      [] of JSON::Any
    end

    # Registers an external attendee for a public calendar event.
    #
    # Delegates to the `register_attendee(event_id, name, email)` function on
    # the PublicEvents driver.  The driver appends the attendee to the calendar
    # event and returns `true` on success.
    #
    # Guest JWTs are accepted provided the system id appears in their roles.
    @[AC::Route::POST("/:system_id/register", body: :params)]
    def register(
      system_id : String,
      params : RegistrationRequest,
    ) : Nil
      if user_token.guest_scope?
        raise Error::Forbidden.new unless user_token.user.roles.includes?(current_control_system.id)
      end

      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: system_id,
        module_name: MODULE_NAME,
        index: 1,
      )
      raise Error::NotFound.new("PublicEvents module not found on system #{system_id}") unless module_id

      remote_driver = RemoteDriver.new(
        sys_id: system_id,
        module_name: MODULE_NAME,
        index: 1,
        user_id: user_token.id,
      ) do |mod_id|
        ::PlaceOS::Model::Module.find!(mod_id).edge_id.as(String)
      end

      result, status_code = remote_driver.exec(
        security: driver_clearance(user_token),
        function: "register_attendee",
        args: Array(JSON::Any).from_json([params.event_id, params.name, params.email].to_json),
        request_id: request_id,
      )

      response.content_type = "application/json"
      render text: result, status: status_code
    rescue e : RemoteDriver::Error
      handle_execute_error(e)
    end
  end
end
