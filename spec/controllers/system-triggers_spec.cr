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

          refresh_elastic(Model::TriggerInstance.table_name)

          params = HTTP::Params.encode({"as_of" => (inst1.updated_at.try &.to_unix).to_s})
          path = "#{path}?#{params}"
          correct_response = until_expected("GET", path, Spec::Authentication.headers) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            contains_correct = results.any?(inst1.id)
            contains_incorrect = results.any?(inst2.id)

            !results.empty? && contains_correct && !contains_incorrect
          end

          correct_response.should be_true
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
    end
  end
end
