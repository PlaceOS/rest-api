require "./application"

module PlaceOS::Api
  class MQTT < Application
    base "/api/engine/v2/mqtt/"

    # skip authentication for the healthcheck
    skip_action :authorize!, only: [:mqtt_user, :mqtt_access]
    skip_action :set_user_id, only: [:mqtt_user, :mqtt_access]

    # For MQTT JWT access: https://github.com/iegomez/mosquitto-go-auth#remote-mode
    # jwt_response_mode: status, jwt_params_mode: form
    @[AC::Route::POST("/user")]
    def mqtt_user : Nil
      mqtt_parse_jwt
    end

    # Sends a form with the following params: topic, clientid, acc (1: read, 2: write, 3: readwrite, 4: subscribe)
    # example payload: acc=4&clientid=clientId-NwsUNfV30&topic=%2A
    @[AC::Route::POST("/access")]
    def mqtt_access(
      topic : String,
      @[AC::Param::Info(name: "acc", description: "access level required")]
      access : MqttAcl,
      clientid : String? = nil
    ) : Nil
      # Skip validation of the JWT as it may have expired.
      # This is acceptable as this route is a permission check for an established connection.
      mqtt_parse_jwt validate: false

      Log.context.set(
        mqtt_client: clientid,
        mqtt_topic: topic,
        mqtt_access: access.to_s,
      )

      head self.class.mqtt_acl_status(access, user_token)
    end

    # MQTT Service communicates via Authorization header.
    # Supported authentication schemes...
    # - x-api-key
    # - JWTs
    protected def mqtt_parse_jwt(validate : Bool = true)
      unless auth = request.headers["Authorization"]?
        raise Error::Unauthorized.new("missing mqtt token")
      end

      case auth.count('.')
      when 1 # work with x-api-key
        @user_token = ::PlaceOS::Model::ApiKey.find_key!(auth.lchop("Bearer ").rstrip).build_jwt
      when 2 # work with jwt-token
        unless token = acquire_token
          raise Error::Unauthorized.new("missing mqtt token")
        end

        begin
          @user_token = ::PlaceOS::Model::UserJWT.decode(token, validate: validate)
        rescue e : JWT::Error
          Log.warn(exception: e) { {message: "bearer malformed", action: "mqtt_access"} }
          raise Error::Unauthorized.new("bearer malformed")
        end
      else
        raise Error::Unauthorized.new("missing mqtt token")
      end

      # Configure logging and check scope
      set_user_id
      can_read
    end

    # Mosquitto MQTT broker accepts a flag enum for its ACL.
    # Source: https://github.com/iegomez/mosquitto-go-auth/blob/master/backends/constants/constants.go
    @[Flags]
    enum MqttAcl
      Read      = 0x01
      Write     = 0x02
      Subscribe = 0x04

      # this is 0x11 on the go-auth side but that wouldn't work with flags properly
      # it doesn't make much sense that MQTT would be checking deny access either
      # so I think this is safe to do.
      Deny = 0x10
    end

    # Evaluate the ACL permissions flags of the JWT
    # - Allows `read` to users
    # - Allows `subscribe` to users
    # - Denies `write` to users
    # - Allows `write` to support users and above
    # - Denies `deny` to all users
    protected def self.mqtt_acl_status(access : MqttAcl, user) : HTTP::Status
      case access
      when .deny?, .none?
        HTTP::Status::FORBIDDEN
      when .write?
        if user.is_support?
          Utils::Scopes.can_scopes_access!(user, {"mqtt"}, Access::Write)
          HTTP::Status::OK
        else
          Log.warn { "insufficient permissions" }
          HTTP::Status::FORBIDDEN
        end
      when .read?, .subscribe?
        HTTP::Status::OK
      else
        Log.warn { "unknown access level requested" }
        HTTP::Status::BAD_REQUEST
      end
    end
  end
end
