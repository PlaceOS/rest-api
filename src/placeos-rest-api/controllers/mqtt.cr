require "./application"

module PlaceOS::Api
  @[AC::MCP(hide: true)]
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
      clientid : String? = nil,
    ) : Nil
      # Legacy connections may outlive their JWT; enforced ACLs validate it afresh.
      mqtt_parse_jwt validate: false

      Log.context.set(
        mqtt_client: clientid,
        mqtt_topic: topic,
        mqtt_access: access.to_s,
      )

      status = self.class.mqtt_acl_status(access, user_token)
      if Utils::Tenancy.enforce? && status.ok?
        required = Model::UserJWT::Scope::Access::None
        required |= Model::UserJWT::Scope::Access::Read if access.read? || access.subscribe?
        required |= Model::UserJWT::Scope::Access::Write if access.write?
        allowed = mqtt_policy.scope_access?({"mqtt"}, required) && TopicAccess.new(mqtt_policy).allowed?(topic, access)
        status = HTTP::Status::FORBIDDEN unless allowed
      end
      head status
    end

    # MQTT Service communicates via Authorization header.
    # Supported authentication schemes...
    # - x-api-key
    # - JWTs
    getter! mqtt_policy : Utils::Tenancy::Policy

    protected def mqtt_parse_jwt(validate : Bool = true)
      auth = request.headers["Authorization"]? || raise Error::Unauthorized.new("missing mqtt token")
      enforced = Utils::Tenancy.enforce?
      case auth.count('.')
      when 1
        key = ::PlaceOS::Model::ApiKey.find_key!(auth.lchop("Bearer ").rstrip)
        if enforced && (key.expired? || key.user.nil? || key.authority.nil?)
          raise Error::Unauthorized.new("invalid mqtt credential")
        end
        @api_key = key
        @user_token = key.build_jwt
      when 2
        token = acquire_token || raise Error::Unauthorized.new("missing mqtt token")
        @user_token = ::PlaceOS::Model::UserJWT.decode(token, validate: enforced || validate)
      else
        raise Error::Unauthorized.new("missing mqtt token")
      end

      if enforced
        token = user_token
        raise Error::Forbidden.new("guest tokens cannot access MQTT") if token.guest_scope?
        authority = ::PlaceOS::Model::Authority.find_by_domain(token.domain)
        raise Error::Unauthorized.new("mqtt authority not found") unless authority
        policy = Utils::Tenancy::Policy.new(token, authority.id.as(String), api_key_id: api_key.try(&.id))
        raise Error::Unauthorized.new("mqtt credential is no longer valid") unless policy.valid?
        @mqtt_policy = policy
        metadata = token.user
        @user_token = ::PlaceOS::Model::UserJWT.new(
          iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, scope: token.scope,
          user: ::PlaceOS::Model::UserJWT::Metadata.new(name: metadata.name, email: metadata.email, permissions: policy.role, roles: metadata.roles),
        )
        allowed = {Access::Read, Access::Write}.any? { |access| policy.scope_access?({"mqtt"}, access) }
        raise Error::Forbidden.new("mqtt scope required") unless allowed
      else
        can_read
      end
      set_user_id
    rescue JWT::Error | ::PgORM::Error::RecordNotFound
      raise Error::Unauthorized.new("invalid mqtt credential")
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

    # Broker filters must identify their resource before wildcard suffixes.
    private class TopicAccess
      alias Permissions = ::PlaceOS::Model::Permissions

      def initialize(@policy : Utils::Tenancy::Policy)
      end

      def allowed?(topic : String, access : MqttAcl) : Bool
        return false unless @policy.valid?
        return true if @policy.scope.cluster?
        parts = topic.split('/')
        return false unless parts.size >= 3 && parts[0] == "placeos"
        return false if parts.any? { |part| part.empty? || part.in?({".", ".."}) }
        return false if parts[1] == "internal"
        wildcard = parts.any? { |part| part.includes?('+') || part.includes?('#') }
        return false if wildcard && !access.subscribe?
        parts.each_with_index do |part, index|
          return false if part.includes?('+') && part != "+"
          return false if part.includes?('#') && (part != "#" || index != parts.size - 1)
        end
        required = Permissions::None
        required |= Permissions::Read if access.read? || access.subscribe?
        required |= Permissions::Operate if access.write?
        return false if required.none?

        if parts[2] == "metadata" && parts.size == 4 && parts[3] != "changed"
          return false if access.write?
          prefix = owner(parts[1])
          return false if known_model_id?(parts[1]) && prefix.nil?
          model_allowed?(parts[3], required, raw: true, bound: prefix)
        elsif parts[2] == "state"
          state_allowed?(parts, required)
        elsif parts[1].starts_with?("authority-")
          authority = ::PlaceOS::Model::Authority.find?(parts[1])
          return false unless authority && @policy.permits?(authority.organisation_id, required, authority.id)
          if parts.size == 4 && parts[3] == "event"
            return false unless @policy.privileged? && @policy.permits?(authority.organisation_id, Permissions::Manage, authority.id)
          end
          parts[2..].all? { |part| !known_model_id?(part) || model_allowed?(part, required, bound: authority.organisation_id) }
        else
          false
        end
      end

      private def known_model_id?(id : String) : Bool
        {"authority-", "zone-", "sys-", "mod-", "driver-", "user-", "oauth_strat-", "ldap_strat-", "adfs_strat-", "storage-", "trig-", "trigger-", "repository-", "broker-"}.any? { |prefix| id.starts_with?(prefix) }
      end

      private def owner(id : String) : UUID?
        case id
        when .starts_with?("authority-") then ::PlaceOS::Model::Authority.find?(id).try(&.organisation_id)
        when .starts_with?("zone-")      then ::PlaceOS::Model::Zone.find?(id).try(&.organisation_id)
        when .starts_with?("sys-")       then ::PlaceOS::Model::ControlSystem.find?(id).try(&.organisation_id)
        when .starts_with?("mod-")       then ::PlaceOS::Model::Module.find?(id).try(&.organisation_id)
        end
      end

      private def organisation_allowed?(id : UUID?, required : Permissions, bound : UUID?) : Bool
        !id.nil? && (bound.nil? || bound == id) && @policy.permits?(id, required)
      end

      private def authority_allowed?(id : String?, required : Permissions, bound : UUID?, sensitive : Bool) : Bool
        return false if sensitive && !@policy.privileged?
        authority = id.try { |value| ::PlaceOS::Model::Authority.find?(value) }
        return false unless authority && (bound.nil? || bound == authority.organisation_id)
        @policy.permits?(authority.organisation_id, sensitive ? Permissions::Manage : required, authority.id)
      end

      private def model_allowed?(id : String, required : Permissions, raw : Bool = false, bound : UUID? = nil) : Bool
        case id
        when .starts_with?("zone-")
          organisation_allowed?(::PlaceOS::Model::Zone.find?(id).try(&.organisation_id), required, bound)
        when .starts_with?("sys-")
          organisation_allowed?(::PlaceOS::Model::ControlSystem.find?(id).try(&.organisation_id), required, bound)
        when .starts_with?("mod-")
          organisation_allowed?(::PlaceOS::Model::Module.find?(id).try(&.organisation_id), required, bound)
        when .starts_with?("driver-")
          raw && !required.operate? && @policy.privileged? && !::PlaceOS::Model::Driver.find?(id).nil?
        when .starts_with?("authority-")
          authority_allowed?(id, required, bound, raw)
        when .starts_with?("user-")
          authority_allowed?(::PlaceOS::Model::User.find?(id).try(&.authority_id), required, bound, raw)
        when .starts_with?("oauth_strat-")
          authority_allowed?(::PlaceOS::Model::OAuthAuthentication.find?(id).try(&.authority_id), required, bound, true)
        when .starts_with?("ldap_strat-")
          authority_allowed?(::PlaceOS::Model::LdapAuthentication.find?(id).try(&.authority_id), required, bound, true)
        when .starts_with?("adfs_strat-")
          authority_allowed?(::PlaceOS::Model::SamlAuthentication.find?(id).try(&.authority_id), required, bound, true)
        when .starts_with?("storage-")
          authority_allowed?(::PlaceOS::Model::Storage.find?(id).try(&.authority_id), required, bound, true)
        else
          # Global infrastructure, secrets and unknown formats are platform-only.
          false
        end
      end

      private def state_allowed?(parts : Array(String), required : Permissions) : Bool
        scope = ::PlaceOS::Model::Zone.find?(parts[1])
        return false unless scope && organisation_allowed?(scope.organisation_id, required, nil)
        system_index = parts.index(&.starts_with?("sys-"))
        return false unless system_index && system_index >= 3 && parts.size > system_index + 4
        system = ::PlaceOS::Model::ControlSystem.find?(parts[system_index])
        return false unless system && organisation_allowed?(system.organisation_id, required, scope.organisation_id)
        return false unless parts[3...system_index].all? { |part| part == "_" || model_allowed?(part, required, bound: scope.organisation_id) }
        driver_id, name, position = parts[system_index + 1], parts[system_index + 2], parts[system_index + 3].to_i?
        return false unless position && position > 0
        modules = system.modules.compact_map { |id| ::PlaceOS::Model::Module.find?(id) }.select(&.resolved_name.==(name))
        mod = modules[position - 1]?
        return false unless mod && mod.driver_id == driver_id && organisation_allowed?(mod.organisation_id, required, scope.organisation_id)
        if name.starts_with?("_")
          return false unless @policy.privileged? && @policy.permits?(mod.organisation_id, Permissions::Manage)
        end
        true
      end
    end
  end
end
