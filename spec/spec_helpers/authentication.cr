require "mutex"

module PlaceOS::Api::Spec::Authentication
  CREATION_LOCK = Mutex.new(protection: :reentrant)

  def self.authenticated(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String) : Tuple(Model::User, HTTP::Headers)
    authentication(sys_admin, support, scope, groups)
  end

  def self.user : Model::User
    CREATION_LOCK.synchronize do
      authenticated.first
    end
  end

  def self.headers(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String) : HTTP::Headers
    CREATION_LOCK.synchronize do
      authenticated.last
    end
  end

  # Yield an authenticated user, and a header with X-API-Key set
  def self.x_api_authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String)
    CREATION_LOCK.synchronize do
      user, headers = authentication(sys_admin, support, scope, groups)

      email = user.email.to_s

      PlaceOS::Model::ApiKey.where(name: email).each &.destroy

      api_key = PlaceOS::Model::ApiKey.new(name: email)
      api_key.user = user
      api_key.x_api_key # Ensure key is present
      api_key.save!

      headers.delete("Authorization")

      headers["X-API-Key"] = api_key.x_api_key.not_nil!

      {user, headers}
    end
  end

  # Yield an authenticated user, and a header with Authorization bearer set
  # This method is synchronised due to the redundant top-level calls.
  def self.authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String)
    CREATION_LOCK.synchronize do
      authenticated_user = generate_auth_user(sys_admin, support, scope, groups)

      headers = HTTP::Headers{
        "Authorization" => "Bearer #{PlaceOS::Model::Generator.jwt(authenticated_user, scope).encode}",
        "Content-Type"  => "application/json",
        "Host"          => "localhost",
      }

      {authenticated_user, headers}
    end
  end

  def self.generate_auth_user(sys_admin, support, scopes, groups = [] of String)
    CREATION_LOCK.synchronize do
      org_zone
      authority = PlaceOS::Model::Authority.find_by_domain("localhost") || PlaceOS::Model::Generator.authority.tap { |a|
        a.domain = "localhost"
        a.config["org_zone"] = JSON::Any.new("zone-perm-org")
      }.save!

      scope_list = scopes.try &.join('-', &.to_s)
      group_list = groups.join('-')
      test_user_email = PlaceOS::Model::Email.new("test-#{"admin-" if sys_admin}#{"supp-" if support}scope-#{scope_list}-#{group_list}rest-api@place.tech")

      PlaceOS::Model::User.where(email: test_user_email.to_s, authority_id: authority.id.as(String)).first? || PlaceOS::Model::Generator.user(authority, support: support, admin: sys_admin).tap do |user|
        user.email = test_user_email
        user.groups = groups
        user.save!
      end
    end
  end

  def self.org_zone
    zone = PlaceOS::Model::Zone.find?("zone-perm-org")
    return zone if zone

    zone = Model::Generator.zone
    zone.id = "zone-perm-org"
    zone.tags = Set.new ["org"]
    zone.save!

    metadata = Model::Generator.metadata("permissions", zone)
    metadata.details = JSON.parse({
      admin:  ["management"],
      manage: ["concierge"],
    }.to_json)

    zone
  end
end
