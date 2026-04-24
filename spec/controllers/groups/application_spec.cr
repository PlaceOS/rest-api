require "../../helper"

module PlaceOS::Api
  describe Groups::Applications do
    base = Groups::Applications.base_route

    ::Spec.before_each { clear_group_tables }

    describe "CRUD (sys_admin)" do
      it "indexes + shows for any authenticated user" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        app = Model::Generator.group_application(authority: authority).save!

        _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        result = client.get(base, headers: user_headers)
        result.status_code.should eq 200
        Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"]).should contain(JSON::Any.new(app.id.to_s))

        show = client.get(File.join(base, app.id.to_s), headers: user_headers)
        show.status_code.should eq 200
      end

      it "rejects create for non-sys_admin" do
        _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        payload = Model::Generator.group_application(authority: authority).to_json
        result = client.post(base, body: payload, headers: user_headers)
        result.status_code.should eq 403
      end

      it "allows create/update/destroy for sys_admin" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        payload = Model::Generator.group_application(authority: authority).to_json
        create = client.post(base, body: payload, headers: Spec::Authentication.headers)
        create.status_code.should eq 201
        created = Model::GroupApplication.from_trusted_json(create.body)

        update = client.patch(
          File.join(base, created.id.to_s),
          body: {name: "renamed"}.to_json,
          headers: Spec::Authentication.headers,
        )
        update.status_code.should eq 200

        delete = client.delete(File.join(base, created.id.to_s), headers: Spec::Authentication.headers)
        delete.success?.should be_true
        Model::GroupApplication.find?(created.id.not_nil!).should be_nil
      end
    end

    it "index supports ?q= substring search on name" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      signage = Model::Generator.group_application(authority: authority)
      signage.name = "Signage-#{Random::Secure.hex(3)}"
      signage.save!
      events = Model::Generator.group_application(authority: authority)
      events.name = "Events-#{Random::Secure.hex(3)}"
      events.save!

      result = client.get("#{base}?q=signage", headers: Spec::Authentication.headers)
      result.status_code.should eq 200
      ids = Array(Hash(String, JSON::Any)).from_json(result.body).map { |e| e["id"].as_s }
      ids.should contain(signage.id.to_s)
      ids.should_not contain(events.id.to_s)
    end

    describe "helper routes" do
      it "effective_permissions returns the user's bitmask on a zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        app = Model::Generator.group_application(authority: authority).save!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root_group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_application_membership(group: root_group, application: app).save!
        Model::Generator.group_user(user: user, group: root_group, permissions: Model::Permissions::Read).save!

        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: root_group, zone: zone, permissions: Model::Permissions::Read).save!

        result = client.get(
          "#{File.join(base, app.id.to_s)}/effective_permissions?zone_id=#{zone.id}",
          headers: headers,
        )
        result.status_code.should eq 200
        body = JSON.parse(result.body)
        body["permissions"].as_i.should eq Model::Permissions::Read.to_i
        body["zone_ids"].as_a.map(&.as_s).should eq [zone.id]
      end

      it "effective_permissions supports batch zone_ids" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        app = Model::Generator.group_application(authority: authority).save!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root_group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_application_membership(group: root_group, application: app).save!
        Model::Generator.group_user(user: user, group: root_group, permissions: Model::Permissions::All).save!

        z1 = Model::Generator.zone.save!
        z2 = Model::Generator.zone.save!
        Model::Generator.group_zone(group: root_group, zone: z1, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: root_group, zone: z2, permissions: Model::Permissions::Update).save!

        result = client.get(
          "#{File.join(base, app.id.to_s)}/effective_permissions?zone_ids=#{z1.id},#{z2.id}",
          headers: headers,
        )
        result.status_code.should eq 200
        body = JSON.parse(result.body)
        body["permissions"].as_i.should eq (Model::Permissions::Read | Model::Permissions::Update).to_i
      end

      it "accessible_zones lists every reachable zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        app = Model::Generator.group_application(authority: authority).save!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root_group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_application_membership(group: root_group, application: app).save!
        Model::Generator.group_user(user: user, group: root_group, permissions: Model::Permissions::Read).save!

        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: root_group, zone: zone, permissions: Model::Permissions::Read).save!

        result = client.get("#{File.join(base, app.id.to_s)}/accessible_zones", headers: headers)
        result.status_code.should eq 200
        body = JSON.parse(result.body)
        body["zone_ids"].as_a.map(&.as_s).should contain(zone.id.not_nil!)
      end
    end
  end
end
