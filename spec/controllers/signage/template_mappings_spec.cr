require "../../helper"

module PlaceOS::Api
  describe SignageTemplateMappings do
    base = SignageTemplateMappings.base_route

    # NOTE: don't clear Zone here — the shared auth helper's org zone
    # ("zone-perm-org") must survive between examples (clearing it orphans
    # its permissions Metadata and later re-creation collides).
    ::Spec.before_each do
      Model::SignageTemplate::SystemTemplate.clear
      Model::SignageTemplate.clear
      Model::Playlist::Item.clear
      clear_group_tables
    end

    describe "CRUD as admin/support" do
      it "applies a template to a display and hydrates the response" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        item = Model::Generator.item(authority: authority).save!
        template = Model::Generator.signage_template(authority: authority)
        template.background_item_id = item.id
        template.save!
        sys = Model::Generator.control_system.save!

        body = {template_id: template.id, control_system_id: sys.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 201

        mapping = JSON.parse(result.body)
        mapping["template_id"].as_s.should eq template.id.to_s
        mapping["control_system_id"].as_s.should eq sys.id.to_s
        mapping["template_details"]["id"].as_s.should eq template.id.to_s
        mapping["template_details"]["background_media"]["id"].as_s.should eq item.id.to_s
      end

      it "applies a template to a zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        template = Model::Generator.signage_template(authority: authority).save!
        zone = Model::Generator.zone.save!

        body = {template_id: template.id, zone_id: zone.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 201

        mapping = JSON.parse(result.body)
        mapping["zone_id"].as_s.should eq zone.id.to_s
        # nil columns are omitted from the serialized response
        mapping["control_system_id"]?.try(&.raw).should be_nil
      end

      it "shows a mapping with hydration and destroys it" do
        mapping = Model::Generator.system_template.save!

        show = client.get(File.join(base, mapping.id.to_s), headers: Spec::Authentication.headers)
        show.status_code.should eq 200
        JSON.parse(show.body)["template_details"]["id"].as_s.should eq mapping.template_id.to_s

        delete = client.delete(File.join(base, mapping.id.to_s), headers: Spec::Authentication.headers)
        delete.status_code.should eq 202
        Model::SignageTemplate::SystemTemplate.find?(mapping.id.as(UUID)).should be_nil
      end

      it "404s for an unknown mapping id" do
        result = client.get(File.join(base, UUID.random.to_s), headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end
    end

    describe "model validation surfacing" do
      it "rejects a mapping with both a display and a zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        template = Model::Generator.signage_template(authority: authority).save!
        sys = Model::Generator.control_system.save!
        zone = Model::Generator.zone.save!

        body = {template_id: template.id, control_system_id: sys.id, zone_id: zone.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 422
      end

      it "rejects a mapping with neither a display nor a zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        template = Model::Generator.signage_template(authority: authority).save!

        body = {template_id: template.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 422
      end

      it "allows a default plus scheduled mappings, rejecting a second default" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        template = Model::Generator.signage_template(authority: authority).save!
        sys = Model::Generator.control_system.save!

        default_body = {template_id: template.id, control_system_id: sys.id}.to_json
        client.post(base, body: default_body, headers: Spec::Authentication.headers).status_code.should eq 201

        scheduled_body = {template_id: template.id, control_system_id: sys.id, schedule: {play_cron: "0 9 * * *"}}.to_json
        client.post(base, body: scheduled_body, headers: Spec::Authentication.headers).status_code.should eq 201

        # second schedule-less mapping for the same pairing
        client.post(base, body: default_body, headers: Spec::Authentication.headers).status_code.should eq 422
      end
    end

    describe "create referential checks" do
      it "404s for an unknown template" do
        sys = Model::Generator.control_system.save!
        body = {template_id: UUID.random, control_system_id: sys.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end

      it "404s for a draft template" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        parent = Model::Generator.signage_template(authority: authority).save!
        draft = Model::Generator.signage_template(authority: authority)
        draft.live_template_id = parent.id
        draft.save!
        sys = Model::Generator.control_system.save!

        body = {template_id: draft.id, control_system_id: sys.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end

      it "404s for a template in a different authority" do
        other = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        template = Model::Generator.signage_template(authority: other).save!
        sys = Model::Generator.control_system.save!

        body = {template_id: template.id, control_system_id: sys.id}.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end

      it "404s for an unknown display or zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        template = Model::Generator.signage_template(authority: authority).save!

        body = {template_id: template.id, control_system_id: "sys-nonexistent"}.to_json
        client.post(base, body: body, headers: Spec::Authentication.headers).status_code.should eq 404

        body = {template_id: template.id, zone_id: "zone-nonexistent"}.to_json
        client.post(base, body: body, headers: Spec::Authentication.headers).status_code.should eq 404
      end
    end

    describe "PATCH /:id" do
      it "updates the schedule" do
        mapping = Model::Generator.system_template.save!

        body = {schedule: {play_cron: "30 8 * * *"}}.to_json
        result = client.patch(File.join(base, mapping.id.to_s), body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        found = Model::SignageTemplate::SystemTemplate.find!(mapping.id.as(UUID))
        found.schedule.as(Model::Playlist::Schedule).play_cron.should eq "30 8 * * *"
        found.default?.should be_false
      end

      it "clears the schedule with an explicit null, making the mapping the default" do
        mapping = Model::Generator.system_template(schedule: Model::Playlist::Schedule.new).save!

        body = {schedule: nil}.to_json
        result = client.patch(File.join(base, mapping.id.to_s), body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        Model::SignageTemplate::SystemTemplate.find!(mapping.id.as(UUID)).default?.should be_true
      end

      it "rejects clearing the schedule when another default exists" do
        template = Model::Generator.signage_template.save!
        sys = Model::Generator.control_system.save!
        Model::Generator.system_template(template: template, control_system: sys).save!
        scheduled = Model::Generator.system_template(template: template, control_system: sys, schedule: Model::Playlist::Schedule.new).save!

        body = {schedule: nil}.to_json
        result = client.patch(File.join(base, scheduled.id.to_s), body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 422
      end

      it "cannot retarget a mapping" do
        sys = Model::Generator.control_system.save!
        other_sys = Model::Generator.control_system.save!
        mapping = Model::Generator.system_template(control_system: sys).save!
        other_template = Model::Generator.signage_template.save!

        body = {control_system_id: other_sys.id, template_id: other_template.id}.to_json
        result = client.patch(File.join(base, mapping.id.to_s), body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        found = Model::SignageTemplate::SystemTemplate.find!(mapping.id.as(UUID))
        found.control_system_id.should eq sys.id
        found.template_id.should eq mapping.template_id
      end
    end

    describe "index" do
      it "filters by display, zone and template" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        template_a = Model::Generator.signage_template(authority: authority).save!
        template_b = Model::Generator.signage_template(authority: authority).save!
        sys = Model::Generator.control_system.save!
        zone = Model::Generator.zone.save!

        on_sys = Model::Generator.system_template(template: template_a, control_system: sys).save!
        on_zone = Model::Generator.system_template(template: template_b, zone: zone).save!

        by_sys = client.get("#{base}?control_system_id=#{sys.id}", headers: Spec::Authentication.headers)
        by_sys.status_code.should eq 200
        Array(Hash(String, JSON::Any)).from_json(by_sys.body).map(&.["id"].as_s).should eq [on_sys.id.to_s]

        by_zone = client.get("#{base}?zone_id=#{zone.id}", headers: Spec::Authentication.headers)
        Array(Hash(String, JSON::Any)).from_json(by_zone.body).map(&.["id"].as_s).should eq [on_zone.id.to_s]

        by_template = client.get("#{base}?template_id=#{template_a.id}", headers: Spec::Authentication.headers)
        Array(Hash(String, JSON::Any)).from_json(by_template.body).map(&.["id"].as_s).should eq [on_sys.id.to_s]
      end

      it "hydrates entries" do
        mapping = Model::Generator.system_template.save!

        result = client.get(base, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        entry = JSON.parse(result.body).as_a.first
        entry["id"].as_s.should eq mapping.id.to_s
        entry["template_details"]["id"].as_s.should eq mapping.template_id.to_s
      end
    end

    describe "regular users via template group membership" do
      it "sees only mappings of templates linked to groups with Read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        visible_template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: visible_template).save!
        hidden_template = Model::Generator.signage_template(authority: authority).save!

        visible = Model::Generator.system_template(template: visible_template).save!
        hidden = Model::Generator.system_template(template: hidden_template).save!

        result = client.get(base, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [visible.id.to_s]

        client.get(File.join(base, visible.id.to_s), headers: headers).status_code.should eq 200
        client.get(File.join(base, hidden.id.to_s), headers: headers).status_code.should eq 403
      end

      it "requires Create on the template's groups to apply it" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!
        sys = Model::Generator.control_system.save!

        body = {template_id: template.id, control_system_id: sys.id}.to_json
        client.post(base, body: body, headers: headers).status_code.should eq 403

        # grant Create via a second membership-equivalent update
        Model::GroupUser.where(user_id: user.id, group_id: group.id.as(UUID)).to_a.first.destroy
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read | Model::Permissions::Create).save!

        client.post(base, body: body, headers: headers).status_code.should eq 201
      end

      it "requires Update to change the schedule and Delete to remove" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!
        mapping = Model::Generator.system_template(template: template).save!

        body = {schedule: {play_cron: "0 9 * * *"}}.to_json
        client.patch(File.join(base, mapping.id.to_s), body: body, headers: headers).status_code.should eq 403
        client.delete(File.join(base, mapping.id.to_s), headers: headers).status_code.should eq 403

        Model::GroupUser.where(user_id: user.id, group_id: group.id.as(UUID)).to_a.first.destroy
        perms = Model::Permissions::Read | Model::Permissions::Update | Model::Permissions::Delete
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        client.patch(File.join(base, mapping.id.to_s), body: body, headers: headers).status_code.should eq 200
        client.delete(File.join(base, mapping.id.to_s), headers: headers).status_code.should eq 202
      end

      it "lets a viewer of a zone see mappings applied to it (read-only)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        # the template itself is NOT linked to any of the user's groups
        template = Model::Generator.signage_template(authority: authority).save!
        mapping = Model::Generator.system_template(template: template, zone: zone).save!

        show = client.get(File.join(base, mapping.id.to_s), headers: headers)
        show.status_code.should eq 200
        JSON.parse(show.body)["template_details"]["id"].as_s.should eq template.id.to_s

        index = client.get(base, headers: headers)
        index.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(index.body).map(&.["id"].as_s)
        ids.should eq [mapping.id.to_s]

        # viewing the target does not grant edit rights
        body = {schedule: {play_cron: "0 9 * * *"}}.to_json
        client.patch(File.join(base, mapping.id.to_s), body: body, headers: headers).status_code.should eq 403
        client.delete(File.join(base, mapping.id.to_s), headers: headers).status_code.should eq 403
      end

      it "lets a viewer of a display see mappings applied to it (read-only)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        sys = Model::Generator.control_system
        sys.zones = [zone.id.as(String)]
        sys.save!

        template = Model::Generator.signage_template(authority: authority).save!
        mapping = Model::Generator.system_template(template: template, control_system: sys).save!

        show = client.get(File.join(base, mapping.id.to_s), headers: headers)
        show.status_code.should eq 200
        JSON.parse(show.body)["template_details"]["id"].as_s.should eq template.id.to_s

        index = client.get(base, headers: headers)
        Array(Hash(String, JSON::Any)).from_json(index.body).map(&.["id"].as_s).should eq [mapping.id.to_s]

        client.delete(File.join(base, mapping.id.to_s), headers: headers).status_code.should eq 403
      end

      it "grants visibility through the zone tree (grant on a parent zone)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        parent_zone = Model::Generator.zone.save!
        child_zone = Model::Generator.zone
        child_zone.parent_id = parent_zone.id
        child_zone.save!

        group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: parent_zone, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        mapping = Model::Generator.system_template(template: template, zone: child_zone).save!

        show = client.get(File.join(base, mapping.id.to_s), headers: headers)
        show.status_code.should eq 200

        index = client.get(base, headers: headers)
        Array(Hash(String, JSON::Any)).from_json(index.body).map(&.["id"].as_s).should eq [mapping.id.to_s]
      end

      it "does not grant visibility via unrelated zones" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        granted_zone = Model::Generator.zone.save!
        other_zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: granted_zone, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        mapping = Model::Generator.system_template(template: template, zone: other_zone).save!

        client.get(File.join(base, mapping.id.to_s), headers: headers).status_code.should eq 403

        index = client.get(base, headers: headers)
        Array(Hash(String, JSON::Any)).from_json(index.body).should be_empty
      end

      it "mappings of unlinked templates are admin-only" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        template = Model::Generator.signage_template(authority: authority).save!
        mapping = Model::Generator.system_template(template: template).save!
        sys = Model::Generator.control_system.save!

        client.get(File.join(base, mapping.id.to_s), headers: headers).status_code.should eq 403

        body = {template_id: template.id, control_system_id: sys.id, schedule: {play_cron: "0 9 * * *"}}.to_json
        client.post(base, body: body, headers: headers).status_code.should eq 403
      end
    end
  end
end
