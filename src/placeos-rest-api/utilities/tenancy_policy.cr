require "placeos-models/grant"
require "placeos-models/api_key"

module PlaceOS::Api::Utils::Tenancy
  # Re-read identity, roles and grants for each decision; sockets retain only
  # their selected organisation and credential identity, never permission caches.
  class Policy
    alias Permissions = ::PlaceOS::Model::Permissions
    alias UserJWT = ::PlaceOS::Model::UserJWT

    getter token : UserJWT
    getter home_authority_id : String
    getter selected_organisation_id : UUID?

    def initialize(@token, @home_authority_id, @selected_organisation_id : UUID? = nil, @api_key_id : String? = nil)
    end

    def home_authority : ::PlaceOS::Model::Authority?
      ::PlaceOS::Model::Authority.find?(home_authority_id)
    end

    def live_user : ::PlaceOS::Model::User?
      ::PlaceOS::Model::User.find?(token.id)
    end

    def live_key : ::PlaceOS::Model::ApiKey?
      @api_key_id.try { |id| ::PlaceOS::Model::ApiKey.find?(id) }
    end

    def valid? : Bool
      return false if (!@api_key_id && token.exp <= Time.utc) || home_authority.nil?
      return true if token.guest_scope? && @api_key_id.nil?
      user = live_user
      return false if user.nil? || user.deleted || user.authority_id != home_authority_id
      if @api_key_id
        key = live_key
        return !key.nil? && !key.expired? && key.user_id == token.id && key.authority_id == home_authority_id
      end
      logged_out = user.logged_out_at
      logged_out.nil? || logged_out < token.iat
    end

    def role : UserJWT::Permissions
      return UserJWT::Permissions::User unless valid?
      return UserJWT::Permissions::User if token.guest_scope?
      if @api_key_id
        return live_key.try(&.permissions) || UserJWT::Permissions::User
      end
      user = live_user.not_nil!
      return user.support ? UserJWT::Permissions::AdminSupport : UserJWT::Permissions::Admin if user.sys_admin
      user.support ? UserJWT::Permissions::Support : UserJWT::Permissions::User
    end

    def privileged? : Bool
      role.is_support? || role.is_admin?
    end

    def scope : Scope
      organisation = home_authority.try(&.organisation)
      partner = organisation.try(&.partner_id).try { |id| ::PlaceOS::Model::Partner.find?(id) }
      return Scope.new(Reach::Organisation, Set(UUID).new, organisation, partner) if organisation.nil? || !valid?
      if privileged? && organisation.partner_staff && partner
        return Scope.new(Reach::Cluster, nil, organisation, partner) if partner.management
        ids = organisation.partner_organisations.to_a.compact_map(&.id).to_set
        reach = Reach::Partner
      else
        ids = Set{organisation.id.as(UUID)}
        reach = Reach::Organisation
      end
      unless token.guest_scope?
        ::PlaceOS::Model::Grant.for_user(token.id).each do |grant|
          next if grant.permission_flags == Permissions::None
          case grant.scope_type
          when ::PlaceOS::Model::Grant::SCOPE_ORGANISATION
            UUID.parse?(grant.scope_id).try { |id| ids << id }
          when ::PlaceOS::Model::Grant::SCOPE_PARTNER
            if id = UUID.parse?(grant.scope_id)
              ::PlaceOS::Model::Organisation.where(partner_id: id).each { |org| org.id.try { |oid| ids << oid } }
            end
          when ::PlaceOS::Model::Grant::SCOPE_AUTHORITY
            ::PlaceOS::Model::Authority.find?(grant.scope_id).try(&.organisation_id).try { |id| ids << id }
          end
        end
      end
      Scope.new(reach, ids, organisation, partner)
    end

    def structural?(organisation_id : UUID?) : Bool
      return false if organisation_id.nil? || !valid?
      home = home_authority.try(&.organisation)
      return false if home.nil?
      return true if home.id == organisation_id
      return false unless privileged? && home.partner_staff
      partner = home.partner_id.try { |id| ::PlaceOS::Model::Partner.find?(id) }
      return false unless partner
      partner.management || ::PlaceOS::Model::Organisation.find?(organisation_id).try(&.partner_id) == partner.id
    end

    def permissions(organisation_id : UUID?, authority_id : String? = nil) : Permissions
      return Permissions::None unless valid?
      return Permissions::None if organisation_id.nil? || (selected_organisation_id && selected_organisation_id != organisation_id)
      return Permissions::All if structural?(organisation_id)
      return Permissions::None if token.guest_scope?
      if authority_id
        authority = ::PlaceOS::Model::Authority.find?(authority_id)
        return Permissions::None unless authority && authority.organisation_id == organisation_id
        return ::PlaceOS::Model::Grant.resolve(token.id, authority)
      end
      organisation = ::PlaceOS::Model::Organisation.find?(organisation_id)
      return Permissions::None unless organisation
      ::PlaceOS::Model::Grant.for_user(token.id).reduce(Permissions::None) do |held, grant|
        applies = case grant.scope_type
                  when ::PlaceOS::Model::Grant::SCOPE_ORGANISATION then grant.scope_id == organisation_id.to_s
                  when ::PlaceOS::Model::Grant::SCOPE_PARTNER      then grant.scope_id == organisation.partner_id.try(&.to_s)
                  else                                                  false
                  end
        applies ? held | grant.permission_flags : held
      end
    end

    def permits?(organisation_id : UUID?, required : Permissions, authority_id : String? = nil) : Bool
      held = permissions(organisation_id, authority_id)
      held.manage? || held.includes?(required)
    end

    def scope_access?(resources : Enumerable(String), access : UserJWT::Scope::Access) : Bool
      return false unless resources.any? { |resource| Utils::Scopes.can_scope_access?(token, resource, access) }
      key = live_key
      key.nil? || resources.any? { |resource| Utils::Scopes.can_scope_access?(key.build_jwt, resource, access) }
    end

    def module_debug_access?(module_id : String) : Bool
      return false unless valid? && scope_access?({"modules", "control"}, UserJWT::Scope::Access::Read)
      mod = ::PlaceOS::Model::Module.find?(module_id)
      required = Permissions::Read | Permissions::Operate
      return false unless mod && permits?(mod.organisation_id, required)
      return true if privileged? || !structural?(mod.organisation_id)
      current = live_user
      return false unless current
      live_token = UserJWT.new(
        iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, scope: token.scope,
        user: UserJWT::Metadata.new(name: current.name.as(String), email: current.email.to_s, permissions: role, roles: current.groups),
      )
      Utils::ModuleDebugAccess.allowed?(live_token, module_id)
    end

    def system_access?(system_id : String, required : Permissions) : Bool
      return false unless valid?
      # Debug consumes Operate permission but only reads the control stream.
      access = required == Permissions::Operate ? UserJWT::Scope::Access::Write : UserJWT::Scope::Access::Read
      return false unless {"systems", "control"}.any? { |resource| Utils::Scopes.can_scope_access?(token, resource, access) }
      if key = live_key
        return false unless {"systems", "control"}.any? { |resource| Utils::Scopes.can_scope_access?(key.build_jwt, resource, access) }
      end
      system = ::PlaceOS::Model::ControlSystem.find?(system_id)
      !system.nil? && permits?(system.organisation_id, required)
    end

    def resource_security(organisation_id : UUID?) : Driver::Proxy::RemoteDriver::Clearance
      user_level = Driver::Proxy::RemoteDriver::Clearance::User
      return user_level unless valid? && permits?(organisation_id, Permissions::Operate)
      unless structural?(organisation_id)
        return permissions(organisation_id).manage? ? Driver::Proxy::RemoteDriver::Clearance::Support : user_level
      end
      return Driver::Proxy::RemoteDriver::Clearance::Admin if role.is_admin?
      role.is_support? ? Driver::Proxy::RemoteDriver::Clearance::Support : user_level
    end

    def system_security(system_id : String) : Driver::Proxy::RemoteDriver::Clearance
      resource_security(::PlaceOS::Model::ControlSystem.find?(system_id).try(&.organisation_id))
    end
  end
end
