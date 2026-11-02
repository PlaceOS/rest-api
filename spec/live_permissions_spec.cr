require "./helper"

module PlaceOS::Api
  # sys_admin / support are capped by the user's current model, so revoking them applies
  # before the JWT expires. API keys deliberately keep their own stored permissions.
  describe "live user permissions" do
    admin_path = ApiKeys.base_route    # check_admin
    support_path = Storages.base_route # check_support

    new_user = ->(sys_admin : Bool, support : Bool) do
      # ensures the "localhost" authority exists
      Spec::Authentication.authentication
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      Model::Generator.user(authority, support: support, admin: sys_admin).save!
    end

    bearer_headers = ->(user : Model::User) do
      jwt = Model::Generator.jwt(user)
      jwt = Model::UserJWT.new(
        iss: jwt.iss,
        iat: jwt.iat,
        exp: jwt.exp,
        domain: "localhost",
        id: jwt.id,
        user: jwt.user,
        scope: jwt.scope,
      )
      HTTP::Headers{
        "Authorization" => "Bearer #{jwt.encode}",
        "Content-Type"  => "application/json",
        "Host"          => "localhost",
      }
    end

    api_key_headers = ->(user : Model::User, permissions : Model::UserJWT::Permissions) do
      key = Model::ApiKey.new(name: "live-permissions-#{user.id}")
      key.user = user
      key.permissions = permissions
      key.x_api_key
      key.save!
      HTTP::Headers{
        "X-API-Key"    => key.x_api_key.not_nil!,
        "Content-Type" => "application/json",
        "Host"         => "localhost",
      }
    end

    it "revokes admin and support from a JWT once the user is demoted" do
      user = new_user.call(true, true)
      headers = bearer_headers.call(user)
      client.get(admin_path, headers: headers).status_code.should eq 200
      client.get(support_path, headers: headers).status_code.should eq 200

      user.sys_admin = false
      user.support = false
      user.save!

      client.get(admin_path, headers: headers).status_code.should eq 403
      client.get(support_path, headers: headers).status_code.should eq 403
    end

    it "downgrades an admin JWT to support when only admin is revoked" do
      user = new_user.call(true, true)
      headers = bearer_headers.call(user)

      user.sys_admin = false
      user.save!

      client.get(admin_path, headers: headers).status_code.should eq 403
      client.get(support_path, headers: headers).status_code.should eq 200
    end

    it "does not elevate a JWT when the user is promoted" do
      user = new_user.call(false, false)
      headers = bearer_headers.call(user)

      user.sys_admin = true
      user.support = true
      user.save!

      client.get(admin_path, headers: headers).status_code.should eq 403
      client.get(support_path, headers: headers).status_code.should eq 403
    end

    it "lets an API key grant more than its owner holds" do
      user = new_user.call(false, false)
      headers = api_key_headers.call(user, Model::UserJWT::Permissions::AdminSupport)

      client.get(admin_path, headers: headers).status_code.should eq 200
      client.get(support_path, headers: headers).status_code.should eq 200
    end

    it "rejects a JWT for a deleted user with 401" do
      user = new_user.call(true, true)
      headers = bearer_headers.call(user)
      user.destroy

      client.get(admin_path, headers: headers).status_code.should eq 401
      client.get(File.join(Users.base_route, "current"), headers: headers).status_code.should eq 401
    end

    it "rejects a JWT for a soft deleted user with 401" do
      user = new_user.call(true, true)
      headers = bearer_headers.call(user)
      user.deleted = true
      user.save!

      client.get(admin_path, headers: headers).status_code.should eq 401
      client.get(File.join(Users.base_route, "current"), headers: headers).status_code.should eq 401
    end

    it "rejects an API key for a soft deleted user with 401" do
      user = new_user.call(false, false)
      headers = api_key_headers.call(user, Model::UserJWT::Permissions::AdminSupport)
      client.get(admin_path, headers: headers).status_code.should eq 200

      user.deleted = true
      user.save!

      client.get(admin_path, headers: headers).status_code.should eq 401
    end
  end
end
