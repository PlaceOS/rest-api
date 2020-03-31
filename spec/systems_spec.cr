require "./helper"

module PlaceOS::Api
  describe Systems do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Systems::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::ControlSystem.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        test_base_index(klass: Model::ControlSystem, controller_klass: Systems)

        it "filters systems by zones" do
          Model::ControlSystem.clear

          num_systems = 5

          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          expected_systems.each do |sys|
            sys.zones = [zone_id]
          end

          systems.each &.save!

          params = HTTP::Params.encode({"zone_id" => zone_id})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            returned_ids = JSON.parse(response.body).as_a.compact_map(&.["id"].as_s).sort
            returned_ids == expected_systems.compact_map(&.id).sort
          end

          found.should be_true
        end

        it "filters systems by modules" do
          num_systems = 5

          mod = Model::Generator.module.save!
          mod_id = mod.id.as(String)

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          expected_systems.each do |sys|
            sys.modules = [mod_id]
          end
          systems.each &.save!

          params = HTTP::Params.encode({"module_id" => mod_id})
          path = "#{base}?#{params}"
          found = until_expected("GET", path, authorization_header) do |response|
            returned_ids = JSON.parse(response.body).as_a.compact_map(&.["id"].as_s).sort
            returned_ids == expected_systems.compact_map(&.id).sort
          end

          found.should be_true
        end
      end

      describe "/:sys_id/module/:module_id" do
        it "removes if not in use by another ControlSystem" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs).save!
          cs.persisted?.should be_true
          mod.persisted?.should be_true

          mod_id = mod.id.as(String)
          cs.update_fields(modules: [mod_id])

          path = base + "#{cs.id}/module/#{mod_id}"

          result = curl(
            method: "DELETE",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          cs = Model::ControlSystem.find(cs.id)

          cs.should_not be_nil
          cs.not_nil!.modules.not_nil!.should_not contain mod_id

          Model::Module.find(mod_id).should be_nil
          {mod, cs}.each &.try &.destroy
        end

        it "keeps module if in use by another ControlSystem" do
          cs1 = Model::Generator.control_system.save!
          cs2 = Model::Generator.control_system.save!
          mod = Model::Generator.module.save!
          cs1.persisted?.should be_true
          cs2.persisted?.should be_true
          mod.persisted?.should be_true

          mod_id = mod.id.as(String)
          # Add module to systems
          cs1.update_fields(modules: [mod_id])
          cs2.update_fields(modules: [mod_id])

          cs1.modules.not_nil!.should contain mod_id
          cs2.modules.not_nil!.should contain mod_id

          path = base + "#{cs1.id}/module/#{mod_id}"

          result = curl(
            method: "DELETE",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          cs1 = Model::ControlSystem.find!(cs1.id)
          cs2 = Model::ControlSystem.find!(cs2.id)

          cs1.modules.not_nil!.should_not contain mod_id
          cs2.modules.not_nil!.should contain mod_id

          Model::Module.find(mod_id).should_not be_nil

          {mod, cs1, cs2}.each &.destroy
        end

        it "adds a module if not present" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module.save!
          cs.persisted?.should be_true
          mod.persisted?.should be_true

          mod_id = mod.id.as(String)
          path = base + "#{cs.id}/module/#{mod_id}"

          result = curl(
            method: "PUT",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          cs = Model::ControlSystem.find!(cs.id)
          cs.modules.not_nil!.should contain mod_id
          {cs, mod}.each &.destroy
        end

        it "404s if added module does not exist" do
          cs = Model::Generator.control_system.save!
          cs.persisted?.should be_true

          path = base + "#{cs.id}/module/mod-th15do35n073x157"

          result = curl(
            method: "PUT",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 404
          cs.destroy
        end
      end

      describe "/:sys_id/settings" do
        it "collates System settings" do
          control_system = Model::Generator.control_system.save!
          control_system_settings_string = %(frangos: 1)
          Model::Generator.settings(control_system: control_system, settings_string: control_system_settings_string).save!

          zone0 = Model::Generator.zone.save!
          zone0_settings_string = %(screen: 1)
          Model::Generator.settings(zone: zone0, settings_string: zone0_settings_string).save!
          zone1 = Model::Generator.zone.save!
          zone1_settings_string = %(meme: 2)
          Model::Generator.settings(zone: zone1, settings_string: zone1_settings_string).save!

          control_system.zones = [zone0.id.as(String), zone1.id.as(String)]
          control_system.update!

          expected_settings_ids = [
            control_system.master_settings,
            zone1.master_settings,
            zone0.master_settings,
          ].flat_map(&.compact_map(&.id)).reverse!

          path = "#{base}#{control_system.id}/settings"
          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          result.success?.should be_true

          settings = Array(Hash(String, JSON::Any)).from_json(result.body)
          settings_hierarchy_ids = settings.map { |s| s["id"].to_s }

          settings_hierarchy_ids.should eq expected_settings_ids
          {control_system, zone0, zone1}.each &.destroy
        end

        it "returns an empty array for a system without associated settings" do
          control_system = Model::Generator.control_system.save!

          zone0 = Model::Generator.zone.save!
          zone1 = Model::Generator.zone.save!

          control_system.zones = [zone0.id.as(String), zone1.id.as(String)]
          control_system.save!
          path = "#{base}#{control_system.id}/settings"

          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          unless result.success?
            puts "\ncode: #{result.status_code} body: #{result.body}"
          end

          result.success?.should be_true
          Array(JSON::Any).from_json(result.body).should be_empty
        end
      end

      describe "module function" do
        it "types" do
          expected = {
            "Display"  => 2,
            "Switcher" => 1,
            "Camera"   => 3,
            "Bookings" => 1,
          }

          cs = Model::Generator.control_system.save!
          mods = expected.flat_map do |name, count|
            count.times.to_a.map do
              mod = Model::Generator.module(control_system: cs)
              mod.custom_name = name
              mod.save!
            end
          end

          path = base + "#{cs.id}/types"

          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          types = Hash(String, Int32).from_json(result.body)

          types.should eq expected

          mods.each &.destroy
          cs.destroy
        end

        pending "functions" do
        end

        pending "state" do
        end

        pending "state_lookup" do
        end

        it "start" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs).save!
          cs.update_fields(modules: [mod.id.as(String)])

          cs.persisted?.should be_true
          mod.persisted?.should be_true
          mod.running.should be_false

          path = base + "#{cs.id}/start"

          result = curl(
            method: "POST",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          Model::Module.find!(mod.id.as(String)).running.should be_true

          mod.destroy
          cs.destroy
        end

        it "stop" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs)
          mod.running = true
          mod.save!
          cs.update_fields(modules: [mod.id.as(String)])

          cs.persisted?.should be_true
          mod.persisted?.should be_true
          mod.running.should be_true

          path = base + "#{cs.id}/stop"

          result = curl(
            method: "POST",
            path: path,
            headers: authorization_header.merge({"Content-Type" => "application/x-www-form-urlencoded"}),
          )

          result.status_code.should eq 200
          Model::Module.find!(mod.id.as(String)).running.should be_false

          mod.destroy
          cs.destroy
        end
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::ControlSystem, controller_klass: Systems)

        describe "update" do
          it "if version is valid" do
            cs = Model::Generator.control_system.save!
            cs.persisted?.should be_true

            original_name = cs.name
            cs.name = Faker::Hacker.noun

            id = cs.id.as(String)

            params = HTTP::Params.encode({"version" => "0"})
            path = "#{base + id}?#{params}"

            result = curl(
              method: "PATCH",
              path: path,
              body: cs.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status_code.should eq 200
            updated = Model::ControlSystem.from_trusted_json(result.body)
            updated.id.should eq cs.id
            updated.name.should_not eq original_name
          end

          it "fails when version is invalid" do
            cs = Model::Generator.control_system.save!
            id = cs.id.as(String)
            cs.persisted?.should be_true

            params = HTTP::Params.encode({"version" => "2"})
            path = "#{base + id}?#{params}"

            result = curl(
              method: "PATCH",
              path: path,
              body: cs.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status_code.should eq 409
          end
        end
      end
    end
  end
end
