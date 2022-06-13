require "mutex"

module PlaceOS::Api::Spec::Authentication
  CREATION_LOCK = Mutex.new(protection: :reentrant)

  class_getter authenticated : Tuple(Model::User, HTTP::Headers) do
    authentication
  end

  class_getter user : Model::User do
    CREATION_LOCK.synchronize do
      authenticated.first
    end
  end

  class_getter headers : HTTP::Headers do
    CREATION_LOCK.synchronize do
      authenticated.last
    end
  end

  # Yield an authenticated user, and a header with X-API-Key set
  def self.x_api_authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC])
    CREATION_LOCK.synchronize do
      user, headers = authentication(sys_admin, support, scope)

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
  def self.authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC])
    CREATION_LOCK.synchronize do
      authenticated_user = generate_auth_user(sys_admin, support, scope)

      headers = HTTP::Headers{
        "Authorization" => "Bearer #{PlaceOS::Model::Generator.jwt(authenticated_user, scope).encode}",
        "Content-Type"  => "application/json",
        "Host"          => "localhost",
      }

      {authenticated_user, headers}
    end
  end

  def self.generate_auth_user(sys_admin, support, scopes)
    CREATION_LOCK.synchronize do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost") || PlaceOS::Model::Generator.authority.tap { |a|
        a.domain = "localhost"
      }.save!

      scope_list = scopes.try &.join('-', &.to_s)
      test_user_email = PlaceOS::Model::Email.new("test-#{"admin-" if sys_admin}#{"supp-" if support}scope-#{scope_list}-rest-api@place.tech")

      PlaceOS::Model::User.where(email: test_user_email, authority_id: authority.id.as(String)).first? || PlaceOS::Model::Generator.user(authority, support: support, admin: sys_admin).tap do |user|
        user.email = test_user_email
        user.save!
      end
    end
  end
end
