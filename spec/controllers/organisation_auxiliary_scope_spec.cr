require "../helper"

module PlaceOS::Api
  describe "organisation ownership beyond estate lists" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    build = -> { fixture = Spec::Tenancy.build }

    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "preserves existing API keys with stored privileges above their owner's role" do
      f = build.call.not_nil!
      key = Model::ApiKey.new(name: "Existing #{random_name}")
      key.user = f.acadian.user
      key.permissions = Model::UserJWT::Permissions::Admin
      secret = key.x_api_key.not_nil!
      key.save!
      headers = Spec::Tenancy.headers(f.acadian.user)
      headers.delete("Authorization")
      headers["X-API-Key"] = secret
      result = client.post(Zones.base_route, headers: headers, body: {name: "Key-owned #{random_name}"}.to_json)
      result.status_code.should eq 201
      JSON.parse(result.body)["organisation_id"].as_s.should eq f.acadian.organisation.id.to_s
    end

    it "requires Manage before a foreign creation grant can mint an administrator API key" do
      f = build.call.not_nil!
      grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s,
        Model::Permissions::Read | Model::Permissions::Create).save!
      name = "Delegated credential #{random_name}"
      path = "#{ApiKeys.base_route}?organisation_id=#{f.acadian.organisation.id}"
      body = {name: name, user_id: f.acadian.user.id, permissions: Model::UserJWT::Permissions::Admin.value}.to_json
      headers = Spec::Tenancy.headers(f.ucla.admin)

      denied = client.post(path, headers: headers, body: body)
      denied.status_code.should eq 403
      Model::ApiKey.where(name: name).count.should eq 0

      grant.permission_flags |= Model::Permissions::Manage
      grant.save!
      allowed = client.post(path, headers: headers, body: body)
      allowed.status_code.should eq 201
      key = Model::ApiKey.find!(JSON.parse(allowed.body)["id"].as_s)
      key.authority_id.should eq f.acadian.authority.id
      key.permissions.should eq Model::UserJWT::Permissions::Admin
    end

    it "allows granted profile updates but requires Manage before changing foreign user privileges" do
      f = build.call.not_nil!
      grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s,
        Model::Permissions::Read | Model::Permissions::Update).save!
      path = "#{Users.base_route}#{f.acadian.user.id}?organisation_id=#{f.acadian.organisation.id}"
      headers = Spec::Tenancy.headers(f.ucla.admin)
      name = "Updated profile #{random_name}"
      client.patch(path, headers: headers, body: {name: name}.to_json).status_code.should eq 200
      Model::User.find!(f.acadian.user.id.as(String)).name.should eq name

      original_digest = Model::User.find!(f.acadian.user.id.as(String)).password_digest
      [{sys_admin: true}, {support: true}, {groups: ["customer-management"]}, {password: "Must need Manage 123!"}].each do |changes|
        client.patch(path, headers: headers, body: changes.to_json).status_code.should eq 403
        user = Model::User.find!(f.acadian.user.id.as(String))
        user.sys_admin.should be_false
        user.support.should be_false
        user.groups.should be_empty
        user.password_digest.should eq original_digest
      end

      grant.permission_flags |= Model::Permissions::Manage
      grant.save!
      client.patch(path, headers: headers, body: {sys_admin: true, support: true, groups: ["customer-management"]}.to_json).status_code.should eq 200
      managed = Model::User.find!(f.acadian.user.id.as(String))
      managed.sys_admin.should be_true
      managed.support.should be_true
      managed.groups.should eq ["customer-management"]
    end

    it "does not reveal customer OAuth and authentication secrets through a read grant" do
      f = build.call.not_nil!
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      app = Model::Generator.doorkeeper_application(owner: f.acadian.authority).save!
      oauth = Model::Generator.oauth_strat(f.acadian.authority).save!
      ldap = Model::Generator.ldap_strat(f.acadian.authority)
      ldap.password = "Directory credential #{random_name}"
      ldap.save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      headers = Spec::Tenancy.headers(f.ucla.admin)

      apps = client.get("#{OAuthApplications.base_route}#{suffix}", headers: headers)
      apps.status_code.should eq 200
      Spec::Tenancy.ids(apps.body).should contain(app.id.to_s)
      apps.body.should_not contain(app.secret)
      ["#{OAuthApplications.base_route}#{app.id}", "#{OAuthAuthentications.base_route}#{oauth.id}",
       OAuthAuthentications.base_route, "#{LdapAuthentications.base_route}#{ldap.id}", LdapAuthentications.base_route].each do |path|
        response = client.get("#{path}#{suffix}", headers: headers)
        {200, 403}.includes?(response.status_code).should be_true
        response.body.should_not contain(app.secret)
        response.body.should_not contain(oauth.client_secret)
        response.body.should_not contain(ldap.password.not_nil!)
      end
    end

    it "refuses tenant consent through a read grant before calling Microsoft Graph" do
      f = build.call.not_nil!
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      WebMock.allow_net_connect = false
      begin
        response = client.get("#{TenantConsent.base_route}/#{f.acadian.authority.id}?organisation_id=#{f.acadian.organisation.id}",
          headers: Spec::Tenancy.headers(f.ucla.admin))
        response.status_code.should eq 403
      ensure
        WebMock.allow_net_connect = true
      end
    end

    it "requires Manage before restoring a deleted customer administrator through a creation grant" do
      f = build.call.not_nil!
      administrator = Model::Generator.user(f.acadian.authority, admin: true).save!
      id = administrator.id.as(String)
      administrator.destroy
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s,
        Model::Permissions::Read | Model::Permissions::Create).save!

      response = client.post("#{History.base_route}undelete?resource_type=user&resource_id=#{id}&organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ucla.admin))
      response.status_code.should eq 403
      Model::User.find?(id).should be_nil
    end

    it "does not restore a selected system after its recorded module belongs to a sibling organisation" do
      f = build.call.not_nil!
      driver = Model::Generator.driver(role: Model::Driver::Role::Device).save!
      mod = Model::Generator.module(driver).tap(&.organisation_id = f.acadian.organisation.id).save!
      deleted = Model::Generator.control_system
      deleted.organisation_id = f.acadian.organisation.id
      deleted.zones = [f.acadian.building.id.as(String)]
      deleted.modules = [mod.id.as(String)]
      deleted.save!
      id = deleted.id.as(String)
      # Keep the device alive when the deleted system releases its modules.
      f.ntt_staff.system.modules = f.ntt_staff.system.modules + [mod.id.as(String)]
      f.ntt_staff.system.save!
      deleted.destroy
      mod.organisation_id = f.ntt_staff.organisation.id
      mod.save!

      response = client.post("#{History.base_route}undelete?resource_type=sys&resource_id=#{id}&organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      response.status_code.should eq 404
      Model::ControlSystem.find?(id).should be_nil
    end

    it "checks changed API key users before saving" do
      f = build.call.not_nil!
      key = Model::ApiKey.new(name: "Stay here #{random_name}")
      key.user = f.acadian.user
      key.save!
      result = client.patch("#{ApiKeys.base_route}#{key.id}?organisation_id=#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {user_id: f.ntt_staff.user.id}.to_json)
      result.status_code.should eq 404
      Model::ApiKey.find!(key.id.as(String)).user_id.should eq f.acadian.user.id
    end

    it "checks changed OAuth owners before saving" do
      f = build.call.not_nil!
      app = Model::Generator.doorkeeper_application(owner: f.acadian.authority).save!
      result = client.patch("#{OAuthApplications.base_route}#{app.id}?organisation_id=#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {owner_id: f.ntt_staff.authority.id}.to_json)
      result.status_code.should eq 404
      Model::DoorkeeperApplication.find!(app.id.not_nil!).owner_id.should eq f.acadian.authority.id
    end

    it "filters metadata children individually when a legacy tree crosses organisations" do
      f = build.call.not_nil!
      f.ntt_staff.building.parent_id = f.acadian.org_zone.id
      f.ntt_staff.building.save!
      result = client.get("#{Metadata.base_route}/#{f.acadian.org_zone.id}/children?organisation_id=#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      result.status_code.should eq 200
      ids = JSON.parse(result.body).as_a.map(&.["zone"]["id"].as_s)
      ids.should contain(f.acadian.building.id)
      ids.should_not contain(f.ntt_staff.building.id)
    end

    it "keeps organisation history available and hides sibling changes" do
      f = build.call.not_nil!
      result = client.get("#{History.base_route}?resource_types=zone", headers: Spec::Tenancy.headers(f.acadian.admin))
      result.status_code.should eq 200
      ids = JSON.parse(result.body).as_a.map(&.["resource_id"].as_s)
      ids.should contain(f.acadian.building.id)
      ids.should_not contain(f.ntt_staff.building.id)
    end

    it "scopes deleted history and restoration using the recorded owner" do
      f = build.call.not_nil!
      zone = Model::Generator.zone.tap { |z| z.name = "Deleted #{random_name}"; z.organisation_id = f.acadian.organisation.id }.save!
      id = zone.id.as(String)
      zone.destroy
      suffix = "organisation_id=#{f.acadian.organisation.id}"
      result = client.get("#{History.base_route}?resource_id=#{id}&#{suffix}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      result.status_code.should eq 200
      JSON.parse(result.body).as_a.map(&.["action"].as_s).should contain("delete")
      restored = client.post("#{History.base_route}undelete?resource_type=zone&resource_id=#{id}&#{suffix}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      restored.status_code.should eq 201
      Model::Zone.find!(id).organisation_id.should eq f.acadian.organisation.id
    end

    it "refuses unrestricted Flux for organisation users before contacting Influx" do
      f = build.call.not_nil!
      headers = Spec::Tenancy.headers(f.acadian.admin)
      headers["Content-Type"] = "application/vnd.flux"
      result = client.post("#{Flux.base_route.rstrip('/')}/query", headers: headers, body: "from(bucket: \"place\") |> range(start: -1m)")
      result.status_code.should eq 403
    end
  end
end
