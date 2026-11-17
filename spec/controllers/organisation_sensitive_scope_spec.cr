require "../helper"

module PlaceOS::Api
  describe "organisation-scoped sensitive configuration and cascading writes" do
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

    it "keeps delegated read and update grants from decrypting or rewriting encrypted settings" do
      f = build.call.not_nil!
      secret = "Encrypted customer credential #{random_name}"
      setting = Model::Generator.settings(settings_string: {password: secret}.to_json,
        encryption_level: Encryption::Level::Admin, control_system: f.acadian.system, modifier: f.acadian.admin).save!
      plain = Model::Generator.settings(settings_string: {public_option: "visible"}.to_json,
        encryption_level: Encryption::Level::None, control_system: f.acadian.system, modifier: f.acadian.admin).save!
      grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s,
        Model::Permissions::Read | Model::Permissions::Update).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      headers = Spec::Tenancy.headers(f.ucla.admin)
      client.get("#{Settings.base_route}#{plain.id}#{suffix}", headers: headers).status_code.should eq 200
      response = client.get("#{Settings.base_route}#{setting.id}#{suffix}", headers: headers)
      {200, 403}.includes?(response.status_code).should be_true
      response.body.should_not contain(secret)
      client.patch("#{Settings.base_route}#{setting.id}#{suffix}", headers: headers, body: "{}").status_code.should eq 403

      grant.permission_flags |= Model::Permissions::Manage
      grant.save!
      managed = client.get("#{Settings.base_route}#{setting.id}#{suffix}", headers: headers)
      managed.status_code.should eq 200
      managed.body.should contain(secret)
    end

    it "does not expose or mutate authority internals through delegated profile updates" do
      f = build.call.not_nil!
      secret = "Authority private credential #{random_name}"
      f.acadian.authority.internals_will_change!
      f.acadian.authority.internals["recaptcha_secret"] = JSON::Any.new(secret)
      f.acadian.authority.save!
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s,
        Model::Permissions::Read | Model::Permissions::Update).save!
      path = "#{Domains.base_route}#{f.acadian.authority.id}?organisation_id=#{f.acadian.organisation.id}"
      headers = Spec::Tenancy.headers(f.ucla.admin)
      view = client.get(path, headers: headers)
      view.status_code.should eq 200
      view.body.should_not contain(secret)
      JSON.parse(view.body)["internals"]?.should be_nil
      updated = client.patch(path, headers: headers, body: {description: "Allowed profile update"}.to_json)
      updated.status_code.should eq 200
      updated.body.should_not contain(secret)
      denied = client.patch(path, headers: headers, body: {internals: {recaptcha_secret: "rewritten"}}.to_json)
      denied.status_code.should eq 403
      Model::Authority.find!(f.acadian.authority.id.as(String)).internals["recaptcha_secret"].as_s.should eq secret
    end

    it "refuses to cascade zone deletion into a sibling organisation's legacy child" do
      f = build.call.not_nil!
      f.ntt_staff.building.parent_id = f.acadian.org_zone.id
      f.ntt_staff.building.save!
      response = client.delete("#{Zones.base_route}#{f.acadian.org_zone.id}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      response.status_code.should eq 404
      Model::Zone.find?(f.acadian.org_zone.id.as(String)).should_not be_nil
      Model::Zone.find?(f.ntt_staff.building.id.as(String)).should_not be_nil

      # The model also prunes references from systems beyond the child tree.
      f.ntt_staff.building.parent_id = f.ntt_staff.org_zone.id
      f.ntt_staff.building.save!
      f.ntt_staff.system.zones = f.ntt_staff.system.zones + [f.acadian.org_zone.id.as(String)]
      f.ntt_staff.system.save!
      referenced = client.delete("#{Zones.base_route}#{f.acadian.org_zone.id}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      referenced.status_code.should eq 404
      Model::Zone.find?(f.acadian.org_zone.id.as(String)).should_not be_nil
      Model::ControlSystem.find!(f.ntt_staff.system.id.as(String)).zones.should contain(f.acadian.org_zone.id)
    end

    it "refuses system deletion that would destroy another organisation's referenced module" do
      f = build.call.not_nil!
      f.ntt_staff.system.modules = [] of String
      f.ntt_staff.system.save!
      f.acadian.system.modules = [f.ntt_staff.mod.id.as(String)]
      f.acadian.system.save!
      response = client.delete("#{Systems.base_route}#{f.acadian.system.id}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      response.status_code.should eq 404
      Model::ControlSystem.find?(f.acadian.system.id.as(String)).should_not be_nil
      Model::Module.find?(f.ntt_staff.mod.id.as(String)).should_not be_nil
    end

    it "refuses module deletion that would rewrite another organisation's referencing system" do
      f = build.call.not_nil!
      f.ntt_staff.system.modules = f.ntt_staff.system.modules + [f.acadian.mod.id.as(String)]
      f.ntt_staff.system.save!
      response = client.delete("#{Modules.base_route}#{f.acadian.mod.id}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      response.status_code.should eq 404
      Model::Module.find?(f.acadian.mod.id.as(String)).should_not be_nil
      Model::ControlSystem.find!(f.ntt_staff.system.id.as(String)).modules.should contain(f.acadian.mod.id)
    end

    it "does not collate settings from a sibling organisation through legacy system zone references" do
      f = build.call.not_nil!
      secret = "Sibling configuration #{random_name}"
      Model::Generator.settings(settings_string: {private_option: secret}.to_json,
        encryption_level: Encryption::Level::None, zone: f.ntt_staff.building, modifier: f.ntt_staff.admin).save!
      f.acadian.system.zones = f.acadian.system.zones + [f.ntt_staff.building.id.as(String)]
      f.acadian.system.save!
      response = client.get("#{Systems.base_route}#{f.acadian.system.id}/settings?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      {200, 404}.includes?(response.status_code).should be_true
      response.body.should_not contain(secret)
    end
    it "keeps nested API key authority internals private for read delegates and preserves home administrator views" do
      f = build.call.not_nil!
      secret = "Nested key authority credential #{random_name}"
      f.acadian.authority.internals_will_change!
      f.acadian.authority.internals["credential"] = JSON::Any.new(secret)
      f.acadian.authority.save!
      key = Model::ApiKey.new(name: "Scoped metadata #{random_name}")
      key.user = f.acadian.user
      key.save!
      grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      headers = Spec::Tenancy.headers(f.ucla.admin)
      ["#{ApiKeys.base_route}#{suffix}", "#{ApiKeys.base_route}#{key.id}#{suffix}"].each do |path|
        response = client.get(path, headers: headers)
        response.status_code.should eq 200
        response.body.should_not contain(secret)
        record = JSON.parse(response.body)
        record = record.as_a.find! { |entry| entry["id"].as_s == key.id } if record.as_a?
        record["authority"]["id"].as_s.should eq f.acadian.authority.id
        record["authority"]["internals"]?.should be_nil
      end

      home = client.get("#{ApiKeys.base_route}#{key.id}", headers: Spec::Tenancy.headers(f.acadian.admin))
      home.status_code.should eq 200
      JSON.parse(home.body)["authority"]["internals"]["credential"].as_s.should eq secret
      grant.permission_flags |= Model::Permissions::Manage
      grant.save!
      managed = client.get("#{ApiKeys.base_route}#{key.id}#{suffix}", headers: headers)
      managed.status_code.should eq 200
      JSON.parse(managed.body)["authority"]["internals"]["credential"].as_s.should eq secret
    end
    it "hides trigger webhook capabilities from read delegates and always redacts their history" do
      f = build.call.not_nil!
      trigger = Model::Generator.trigger(f.acadian.system).tap(&.organisation_id = f.acadian.organisation.id).save!
      instance = Model::Generator.trigger_instance(trigger, control_system: f.acadian.system).save!
      secret = instance.webhook_secret
      grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      system_base = SystemTriggers.base_route.gsub(":sys_id", f.acadian.system.id.as(String))
      suffix = "organisation_id=#{f.acadian.organisation.id}"
      headers = Spec::Tenancy.headers(f.ucla.admin)
      paths = ["#{system_base}?#{suffix}", "#{system_base}#{instance.id}?#{suffix}",
               "#{Triggers.base_route}#{trigger.id}?instances=true&#{suffix}", "#{Triggers.base_route}#{trigger.id}/instances?#{suffix}"]
      paths.each do |path|
        response = client.get(path, headers: headers)
        response.status_code.should eq 200
        response.body.should_not contain(secret)
      end

      history_path = "#{History.base_route}?resource_types=trig&resource_id=#{instance.id}&actions=create&#{suffix}"
      history = client.get(history_path, headers: headers)
      history.status_code.should eq 200
      JSON.parse(history.body).as_a.map(&.["resource_id"].as_s).should contain(instance.id)
      history.body.should_not contain(secret)

      home = client.get("#{system_base}#{instance.id}", headers: Spec::Tenancy.headers(f.acadian.admin))
      home.status_code.should eq 200
      JSON.parse(home.body)["webhook_secret"].as_s.should eq secret
      grant.permission_flags |= Model::Permissions::Manage
      grant.save!
      managed = client.get("#{system_base}#{instance.id}?#{suffix}", headers: headers)
      managed.status_code.should eq 200
      JSON.parse(managed.body)["webhook_secret"].as_s.should eq secret
      client.get(history_path, headers: headers).body.should_not contain(secret)
    end

    it "does not instantiate another reachable organisation's bound trigger in the selected system" do
      f = build.call.not_nil!
      foreign = Model::Generator.trigger(f.ntt_staff.system).tap(&.organisation_id = f.ntt_staff.organisation.id).save!
      path = SystemTriggers.base_route.gsub(":sys_id", f.acadian.system.id.as(String))
      result = client.post("#{path}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {trigger_id: foreign.id}.to_json)
      result.status_code.should eq 404
      Model::TriggerInstance.where(control_system_id: f.acadian.system.id, trigger_id: foreign.id).count.should eq 0
    end
    it "does not turn a delegated staff organisation grant into partner or cluster credentials" do
      f = build.call.not_nil!
      [f.ntt_staff, f.placeos].each do |staff|
        Model::Generator.grant(f.ucla.admin, "organisation", staff.organisation.id.to_s, Model::Permissions::Manage).save!
        before = client.get("#{Zones.base_route}#{f.acadian.building.id}?organisation_id=#{f.acadian.organisation.id}",
          headers: Spec::Tenancy.headers(f.ucla.admin))
        before.status_code.should eq 404
        name = "No delegated staff credential #{random_name}"
        path = "#{ApiKeys.base_route}?organisation_id=#{staff.organisation.id}"
        body = {name: name, user_id: staff.user.id, permissions: Model::UserJWT::Permissions::Admin.value}.to_json
        denied = client.post(path, headers: Spec::Tenancy.headers(f.ucla.admin), body: body)
        denied.status_code.should eq 403
        Model::ApiKey.where(name: name).count.should eq 0

        # Existing structural partner / management administrators retain the
        # ability to create keys with stored privileges above their owner.
        allowed = client.post(path, headers: Spec::Tenancy.headers(staff.admin),
          body: {name: "Structural staff credential #{random_name}", user_id: staff.user.id,
                 permissions: Model::UserJWT::Permissions::Admin.value}.to_json)
        allowed.status_code.should eq 201
      end
    end
  end
end
