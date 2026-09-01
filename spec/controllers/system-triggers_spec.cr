require "../helper"
require "timecop"

module PlaceOS::Api
  describe SystemTriggers do
    Spec.test_404(
      SystemTriggers.base_route.gsub(/:sys_id/, "sys-#{Random.rand(9999)}"),
      model_name: Model::TriggerInstance.table_name,
      headers: Spec::Authentication.headers,
    )

    describe "index", tags: "search" do
      context "query parameter" do
        it "as_of" do
          sys = Model::Generator.control_system.save!
          path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id)

          inst1 = Model::Generator.trigger_instance
          inst1.control_system = sys
          Timecop.freeze(2.days.ago) do
            inst1.save!
          end
          inst1.persisted?.should be_true

          inst2 = Model::Generator.trigger_instance
          inst2.control_system = sys
          inst2.save!
          inst2.persisted?.should be_true

          params = HTTP::Params.encode({"as_of" => (inst1.updated_at.try &.to_unix).to_s})
          path = "#{path}?#{params}"

          result = client.get(path: path, headers: Spec::Authentication.headers)
          result.status_code.should eq 200

          results = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          results.should contain(inst1.id)
          results.should_not contain(inst2.id)
        end

        it "trigger_id" do
          sys = Model::Generator.control_system.save!
          base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id)

          trigger1 = Model::Generator.trigger.save!
          trigger2 = Model::Generator.trigger.save!
          inst1 = Model::Generator.trigger_instance(trigger1, control_system: sys).save!
          inst2 = Model::Generator.trigger_instance(trigger2, control_system: sys).save!

          params = HTTP::Params.encode({"trigger_id" => trigger1.id.as(String)})
          result = client.get(path: "#{base}?#{params}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200

          results = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          results.should contain(inst1.id)
          results.should_not contain(inst2.id)

          {inst1, inst2, trigger1, trigger2, sys}.each &.destroy
        end

        it "important and triggered filter only when true" do
          sys = Model::Generator.control_system.save!
          base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id)

          # NOTE: set flags via update — `before_create :set_importance`
          # overwrites `important` with the parent trigger's value on create
          flagged = Model::Generator.trigger_instance(control_system: sys).save!
          flagged.important = true
          flagged.triggered = true
          flagged.save!

          plain = Model::Generator.trigger_instance(control_system: sys).save!

          # no params => both returned
          result = client.get(path: base, headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          results = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          results.should contain(flagged.id)
          results.should contain(plain.id)

          # important=true => only the important instance
          result = client.get(path: "#{base}?important=true", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          results = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          results.should contain(flagged.id)
          results.should_not contain(plain.id)

          # triggered=true => only the triggered instance
          result = client.get(path: "#{base}?triggered=true", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          results = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          results.should contain(flagged.id)
          results.should_not contain(plain.id)

          {flagged, plain, sys}.each &.destroy
        end

        # Pins the PPT-2644 fix: under Elasticsearch the `q` param on this
        # route was a silent no-op (the has_parent `should` clause was never
        # required as minimum_should_match was unset). `q` now searches the
        # parent trigger's text.
        it "q searches by parent trigger name" do
          sys = Model::Generator.control_system.save!
          base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id)

          trigger = Model::Generator.trigger
          trigger.name = "Motion Detected"
          trigger.save!
          inst = Model::Generator.trigger_instance(trigger, control_system: sys).save!

          other_trigger = Model::Generator.trigger
          other_trigger.name = "Door Held Open"
          other_trigger.save!
          other_inst = Model::Generator.trigger_instance(other_trigger, control_system: sys).save!

          # q matching the parent trigger's name returns its instance only
          result = client.get(path: "#{base}?q=motion", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          results = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          results.should contain(inst.id)
          results.should_not contain(other_inst.id)

          # q matching no trigger returns no instances
          result = client.get(path: "#{base}?q=nonsensequery", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          Array(Hash(String, JSON::Any)).from_json(result.body).should be_empty

          {inst, other_inst, trigger, other_trigger, sys}.each &.destroy
        end
      end
    end

    describe "CRUD operations", tags: "crud" do
      it "create" do
        sys = Model::Generator.control_system.save!
        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        body = trigger_instance.to_json

        path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id)
        result = client.post(
          path: path,
          body: body,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 201
        body = result.body.not_nil!
        Model::TriggerInstance.find(JSON.parse(body)["id"].as_s).try &.destroy
      end

      it "show" do
        sys = Model::Generator.control_system.save!
        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        trigger_instance.save!
        id = trigger_instance.id.not_nil!

        path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id) + id
        result = client.get(path: path, headers: Spec::Authentication.headers)

        result.status_code.should eq 200

        response_model = Model::TriggerInstance.from_trusted_json(result.body)
        response_model.id.should eq id

        sys.destroy
        trigger_instance.destroy
      end

      it "update" do
        sys = Model::Generator.control_system.save!
        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        trigger_instance.save!

        original_importance = trigger_instance.important
        updated_importance = !original_importance

        id = trigger_instance.id.not_nil!
        path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id) + id

        result = client.patch(
          path: path,
          body: {important: updated_importance}.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::TriggerInstance.from_trusted_json(result.body)

        updated.id.should eq trigger_instance.id
        updated.important.should_not eq original_importance
        updated.destroy
      end

      it "destroy" do
        sys = PlaceOS::Model::Generator.control_system.save!
        model = PlaceOS::Model::Generator.trigger_instance
        model.control_system = sys

        model.save!
        model.persisted?.should be_true

        id = model.id.not_nil!
        path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id) + id

        result = client.delete(path: path, headers: Spec::Authentication.headers)
        result.success?.should be_true

        Model::TriggerInstance.find?(id.as(String)).should be_nil
      end
    end

    describe "support-subsystem permissions" do
      ::Spec.before_each { clear_group_tables }

      # A control system scoped to `zone`, plus a persisted trigger instance
      # attached to it. The instance inherits the system's zones, so granting
      # on `zone` (via a "support" GroupZone) gates index/show/mutations.
      support_system_setup = ->(zone : Model::Zone) {
        sys = Model::Generator.control_system
        sys.zones = [zone.id.as(String)]
        sys.save!
        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        trigger_instance.save!
        {sys, trigger_instance}
      }

      it "allows GET index/show with Read on the system zone, rejects without" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        sys, trigger_instance = support_system_setup.call(zone)

        base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String))
        show_path = base + trigger_instance.id.as(String)

        # no group reach yet => denied
        result = client.get(path: base, headers: headers)
        result.status_code.should eq 403
        result = client.get(path: show_path, headers: headers)
        result.status_code.should eq 403

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        result = client.get(path: show_path, headers: headers)
        result.status_code.should eq 200
        Model::TriggerInstance.from_trusted_json(result.body).id.should eq trigger_instance.id

        trigger_instance.destroy
        sys.destroy
        zone.destroy
      end

      it "allows POST create with Create on both sides, rejects with only Read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        sys = Model::Generator.control_system
        sys.zones = [zone.id.as(String)]
        sys.save!

        base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String))

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        body = trigger_instance.to_json

        # only Read => create denied
        result = client.post(path: base, body: body, headers: headers)
        result.status_code.should eq 403

        # grant Create on both sides => allowed
        gu.permissions = Model::Permissions::Create.to_i
        gu.save!
        gz.permissions = Model::Permissions::Create.to_i
        gz.save!

        result = client.post(path: base, body: body, headers: headers)
        result.status_code.should eq 201
        Model::TriggerInstance.find?(JSON.parse(result.body)["id"].as_s).try &.destroy

        sys.destroy
        zone.destroy
      end

      it "gates PATCH update on Update and DELETE on Delete" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        sys, trigger_instance = support_system_setup.call(zone)

        base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String))
        path = base + trigger_instance.id.as(String)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        # only Read => update denied
        result = client.patch(path: path, body: {important: true}.to_json, headers: headers)
        result.status_code.should eq 403

        # Update on both sides => allowed
        gu.permissions = Model::Permissions::Update.to_i
        gu.save!
        gz.permissions = Model::Permissions::Update.to_i
        gz.save!
        result = client.patch(path: path, body: {important: true}.to_json, headers: headers)
        result.status_code.should eq 200

        # Update does not grant Delete => destroy denied
        result = client.delete(path: path, headers: headers)
        result.status_code.should eq 403
        Model::TriggerInstance.find?(trigger_instance.id.as(String)).should_not be_nil

        # Delete on both sides => allowed
        gu.permissions = Model::Permissions::Delete.to_i
        gu.save!
        gz.permissions = Model::Permissions::Delete.to_i
        gz.save!
        result = client.delete(path: path, headers: headers)
        result.success?.should be_true
        Model::TriggerInstance.find?(trigger_instance.id.as(String)).should be_nil

        sys.destroy
        zone.destroy
      end

      it "lets admin/support JWT users bypass the support gate" do
        zone = Model::Generator.zone.save!
        sys, trigger_instance = support_system_setup.call(zone)

        base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String))
        show_path = base + trigger_instance.id.as(String)

        # support JWT can read without any group
        result = client.get(
          path: show_path,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 200

        # admin JWT can destroy without any group
        result = client.delete(
          path: show_path,
          headers: Spec::Authentication.headers(sys_admin: true, support: true),
        )
        result.success?.should be_true
        Model::TriggerInstance.find?(trigger_instance.id.as(String)).should be_nil

        sys.destroy
        zone.destroy
      end

      it "404s when the trigger instance belongs to a different system" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        # the caller holds Manage on system A's zone...
        zone_a = Model::Generator.zone.save!
        sys_a = Model::Generator.control_system
        sys_a.zones = [zone_a.id.as(String)]
        sys_a.save!

        # ...but the trigger instance belongs to system B
        zone_b = Model::Generator.zone.save!
        sys_b, other_instance = support_system_setup.call(zone_b)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Manage).save!
        Model::Generator.group_zone(group: group, zone: zone_a, permissions: Model::Permissions::Manage).save!

        path = SystemTriggers.base_route.gsub(/:sys_id/, sys_a.id.as(String)) + other_instance.id.as(String)

        client.get(path: path, headers: headers).status_code.should eq 404
        client.patch(path: path, body: {important: true}.to_json, headers: headers).status_code.should eq 404
        client.delete(path: path, headers: headers).status_code.should eq 404
        Model::TriggerInstance.find?(other_instance.id.as(String)).should_not be_nil

        # the mismatch is a 404 for admins too
        client.get(path: path, headers: Spec::Authentication.headers).status_code.should eq 404

        other_instance.destroy
        sys_a.destroy
        sys_b.destroy
        zone_a.destroy
        zone_b.destroy
      end

      it "reveals webhook_secret on show to Read grants and admin/support JWTs" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        sys, trigger_instance = support_system_setup.call(zone)
        secret = trigger_instance.webhook_secret

        show_path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String)) + trigger_instance.id.as(String)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        # subsystem Read grant => secret visible
        result = client.get(path: show_path, headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["webhook_secret"]?.try(&.as_s?).should eq secret

        # Manage (a Read superset) => secret visible
        gu.permissions = Model::Permissions::Manage.to_i
        gu.save!
        gz.permissions = Model::Permissions::Manage.to_i
        gz.save!
        result = client.get(path: show_path, headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["webhook_secret"]?.try(&.as_s?).should eq secret

        # support JWT => secret visible (previously admin only)
        result = client.get(path: show_path, headers: Spec::Authentication.headers(sys_admin: false, support: true))
        result.status_code.should eq 200
        JSON.parse(result.body)["webhook_secret"]?.try(&.as_s?).should eq secret

        # admin JWT => secret visible
        result = client.get(path: show_path, headers: Spec::Authentication.headers(sys_admin: true, support: true))
        result.status_code.should eq 200
        JSON.parse(result.body)["webhook_secret"]?.try(&.as_s?).should eq secret

        trigger_instance.destroy
        sys.destroy
        zone.destroy
      end

      it "hides webhook_secret from write-only grants on update responses" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        sys, trigger_instance = support_system_setup.call(zone)
        path = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String)) + trigger_instance.id.as(String)

        # Update without Read passes the write gate but does not see the secret
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Update).save!

        result = client.patch(path: path, body: {important: true}.to_json, headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["webhook_secret"]?.try(&.as_s?).should be_nil

        trigger_instance.destroy
        sys.destroy
        zone.destroy
      end

      it "hides webhook_secret on create for Create-only grants, reveals with Create|Read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        sys = Model::Generator.control_system
        sys.zones = [zone.id.as(String)]
        sys.save!

        base = SystemTriggers.base_route.gsub(/:sys_id/, sys.id.as(String))

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Create).save!

        # Create without Read => created, but the secret is stripped from the response
        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        result = client.post(path: base, body: trigger_instance.to_json, headers: headers)
        result.status_code.should eq 201
        body = JSON.parse(result.body)
        body["webhook_secret"]?.try(&.as_s?).should be_nil
        # the persisted instance still holds a secret
        created = Model::TriggerInstance.find!(body["id"].as_s)
        created.webhook_secret.should_not be_nil
        created.destroy

        # Create|Read => created and the secret is returned
        gu.permissions = (Model::Permissions::Create | Model::Permissions::Read).to_i
        gu.save!
        gz.permissions = (Model::Permissions::Create | Model::Permissions::Read).to_i
        gz.save!

        trigger_instance = Model::Generator.trigger_instance
        trigger_instance.control_system = sys
        result = client.post(path: base, body: trigger_instance.to_json, headers: headers)
        result.status_code.should eq 201
        body = JSON.parse(result.body)
        body["webhook_secret"]?.try(&.as_s?).should_not be_nil
        Model::TriggerInstance.find?(body["id"].as_s).try &.destroy

        sys.destroy
        zone.destroy
      end
    end
  end
end
