require "../helper"

module PlaceOS::Api
  private def self.zone_exec_headers(user : Model::User, scopes : Array(Model::UserJWT::Scope)) : HTTP::Headers
    headers = Spec::Tenancy.headers(user)
    token = Model::UserJWT.decode(headers["Authorization"].split(' ').last)
    headers["Authorization"] = "Bearer #{Model::UserJWT.new(iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, user: token.user, scope: scopes).encode}"
    headers
  end

  private def self.zone_exec_interface(mod : Model::Module)
    metadata = Driver::DriverModel::Metadata.new(
      interface: {"ordinary" => {} of String => JSON::Any, "support_only" => {} of String => JSON::Any, "admin_only" => {} of String => JSON::Any},
      implements: [] of String,
      security: {"support" => ["support_only"], "administrator" => ["admin_only"]},
    )
    Driver::RedisStorage.with_redis &.set("interface/#{mod.id}", metadata.to_json)
  end

  describe "zone execution authorisation" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    commands = [] of String
    before_each do
      Utils::Tenancy.enforce = true
      commands.clear
      WebMock.stub(:post, /\/api\/core\/v1\/command\/.*\/execute/).to_return do |request|
        commands << request.path
        HTTP::Client::Response.new(200, "true")
      end
    end
    after_each do
      Utils::Tenancy.enforce = false
      if cleanup = fixture
        Spec::Tenancy.teardown(cleanup)
        fixture = nil
      end
    end
    prepare = -> {
      fixture = f = Spec::Tenancy.build
      wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
      zone_exec_interface(f.acadian.mod)
      f
    }

    it "executes with Operate on the addressed zone without separate system or module grants" do
      f = prepare.call
      group = Model::Generator.group(authority: f.acadian.authority, subsystems: ["support"]).save!
      Model::Generator.group_user(user: f.acadian.user, group: group, permissions: Model::Permissions::Operate).save!
      Model::Generator.group_zone(group: group, zone: f.acadian.building, permissions: Model::Permissions::Operate).save!
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/ordinary"
      response = client.post(path, headers: Spec::Tenancy.headers(f.acadian.user), body: "[]")
      response.status_code.should eq 200
      JSON.parse(response.body)["success"].as_a.map(&.as_s).should eq [f.acadian.system.id.as(String)]
      commands.size.should eq 1
    end

    it "uses Operate rather than POST Create when evaluating an exact organisation grant" do
      f = prepare.call
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read | Model::Permissions::Operate).save!
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/ordinary?organisation_id=#{f.acadian.organisation.id}"
      response = client.post(path, headers: Spec::Tenancy.headers(f.ucla.admin), body: "[]")
      response.status_code.should eq 200
      JSON.parse(response.body)["success"].as_a.map(&.as_s).should eq [f.acadian.system.id.as(String)]
      commands.size.should eq 1
    end

    it "does not let Read or Create substitute for Operate on the addressed zone" do
      f = prepare.call
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/ordinary?organisation_id=#{f.acadian.organisation.id}"
      [Model::Permissions::Read, Model::Permissions::Read | Model::Permissions::Create].each do |permissions|
        grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, permissions).save!
        client.post(path, headers: Spec::Tenancy.headers(f.ucla.admin), body: "[]").status_code.should eq 403
        grant.destroy
      end
      commands.should be_empty
    end

    it "does not let a Read or Create group-zone grant execute" do
      f = prepare.call
      group = Model::Generator.group(authority: f.acadian.authority, subsystems: ["support"]).save!
      Model::Generator.group_user(user: f.acadian.user, group: group, permissions: Model::Permissions::All).save!
      anchor = Model::Generator.group_zone(group: group, zone: f.acadian.building, permissions: Model::Permissions::Read).save!
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/ordinary"
      [Model::Permissions::Read, Model::Permissions::Create].each do |permissions|
        anchor.update_fields(permissions: permissions.to_i)
        client.post(path, headers: Spec::Tenancy.headers(f.acadian.user), body: "[]").status_code.should eq 403
      end
      commands.should be_empty
    end

    it "intersects zone operation permission with OAuth and API-key write scopes" do
      f = prepare.call
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/ordinary"
      read_scope = [Model::UserJWT::Scope.new("zones", Model::UserJWT::Scope::Access::Read)]
      client.post(path, headers: zone_exec_headers(f.acadian.admin, read_scope), body: "[]").status_code.should eq 403
      key = Model::ApiKey.new(name: "Read-only zones #{random_name}", scopes: read_scope, permissions: Model::UserJWT::Permissions::Admin)
      key.user = f.acadian.admin
      key.save!
      headers = HTTP::Headers{"Host" => f.acadian.authority.domain, "Content-Type" => "application/json", "X-API-Key" => key.x_api_key.not_nil!}
      client.post(path, headers: headers, body: "[]").status_code.should eq 403
      commands.should be_empty
      write_scope = [Model::UserJWT::Scope.new("zones", Model::UserJWT::Scope::Access::Write)]
      client.post(path, headers: zone_exec_headers(f.acadian.admin, write_scope), body: "[]").status_code.should eq 200
      commands.size.should eq 1
    end

    it "derives clearance from the selected zone instead of the home administrator role" do
      f = prepare.call
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read | Model::Permissions::Operate).save!
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/admin_only?organisation_id=#{f.acadian.organisation.id}"
      response = client.post(path, headers: Spec::Tenancy.headers(f.ucla.admin), body: "[]")
      response.status_code.should eq 200
      JSON.parse(response.body)["failure"].as_a.map(&.as_s).should eq [f.acadian.system.id.as(String)]
      commands.should be_empty
    end

    it "does not dispatch a foreign system corruptly referencing the authorised zone" do
      f = prepare.call
      f.ucla.mod.update_fields(custom_name: f.acadian.mod.resolved_name)
      f.ucla.system.update_fields(zones: f.ucla.system.zones + [f.acadian.building.id.as(String)])
      wait_for_module_lookups(f.ucla.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.ucla.mod.id.as(String)})
      zone_exec_interface(f.ucla.mod)
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{f.acadian.mod.resolved_name}/ordinary"
      response = client.post(path, headers: Spec::Tenancy.headers(f.acadian.admin), body: "[]")
      response.status_code.should eq 200
      JSON.parse(response.body)["success"].as_a.map(&.as_s).should_not contain(f.ucla.system.id)
      commands.none?(&.includes?(f.ucla.mod.id.as(String))).should be_true
    end

    it "does not dispatch a foreign runtime alias through an owned system" do
      f = prepare.call
      name = f.acadian.mod.resolved_name
      zone_exec_interface(f.ucla.mod)
      Driver::RedisStorage.new(f.acadian.system.id.as(String), "system")["#{name}/1"] = f.ucla.mod.id.as(String)
      path = "#{Zones.base_route}#{f.acadian.building.id}/exec/#{name}/ordinary"
      response = client.post(path, headers: Spec::Tenancy.headers(f.acadian.admin), body: "[]")
      response.status_code.should eq 200
      JSON.parse(response.body)["success"].as_a.should be_empty
      commands.should be_empty
    end
  end
end
