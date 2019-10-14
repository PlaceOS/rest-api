require "./helper"

module ACAEngine::Api
  describe Systems do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Systems::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::ControlSystem.table_name, headers: authorization_header)

      describe "index" do
        test_base_index(klass: Model::ControlSystem, controller_klass: Systems)

        it "filters systems by zones" do
          num_systems = 5

          zone = Model::Generator.zone.save!
          zone_id = zone.id.not_nil!

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          expected_systems.each do |sys|
            sys.zones = [zone_id]
          end

          systems.each &.save!

          sleep 2

          params = HTTP::Params.encode({"zone_id" => zone_id})
          path = "#{base}?#{params}"
          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          returned_ids = (JSON.parse(result.body)["results"].as_a.compact_map &.["id"].as_s).sort
          returned_ids.should eq (expected_systems.compact_map &.id).sort
        end

        it "filters systems by modules" do
          num_systems = 5

          mod = Model::Generator.module.save!
          mod_id = mod.id.not_nil!

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          expected_systems.each do |sys|
            sys.modules = [mod_id]
          end

          systems.each &.save!

          sleep 2

          params = HTTP::Params.encode({"module_id" => mod_id})
          path = "#{base}?#{params}"
          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          returned_ids = (JSON.parse(result.body)["results"].as_a.compact_map &.["id"].as_s).sort
          returned_ids.should eq (expected_systems.compact_map &.id).sort
        end
      end

      describe "remove" do
        it "module if not in use by another ControlSystem" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs).save!

          mod_id = mod.id.not_nil!
          cs.update_fields(modules: [mod_id])

          cs.persisted?.should be_true
          mod.persisted?.should be_true
          cs.modules.not_nil!.should contain mod_id

          params = HTTP::Params.encode({module_id: mod_id})
          path = base + "#{cs.id}/remove?#{params}"

          result = curl(
            method: "POST",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          cs = Model::ControlSystem.find!(cs.id)
          cs.modules.not_nil!.should_not contain mod_id

          Model::Module.find(mod_id).should be_nil
          cs.destroy
        end

        it "keeps module if in use by another ControlSystem" do
          cs1 = Model::Generator.control_system.save!
          cs2 = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs1).save!

          mod_id = mod.id.not_nil!

          cs1.update_fields(modules: [mod_id])
          cs2.update_fields(modules: [mod_id])

          cs1.persisted?.should be_true
          cs2.persisted?.should be_true
          mod.persisted?.should be_true

          cs1.modules.not_nil!.should contain mod_id
          cs2.modules.not_nil!.should contain mod_id

          params = HTTP::Params.encode({module_id: mod_id})
          path = base + "#{cs1.id}/remove?#{params}"

          result = curl(
            method: "POST",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200

          cs1 = Model::ControlSystem.find!(cs1.id)
          cs2 = Model::ControlSystem.find!(cs2.id)

          cs1.modules.not_nil!.should_not contain mod_id
          cs2.modules.not_nil!.should contain mod_id

          Model::Module.find(mod_id).should_not be_nil

          mod.destroy
          cs1.destroy
          cs2.destroy
        end
      end

      describe "module function" do
        pending "count"
        pending "types"
        pending "exec"

        it "start" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs).save!
          cs.update_fields(modules: [mod.id.not_nil!])

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
          Model::Module.find!(mod.id.not_nil!).running.should be_true

          mod.destroy
          cs.destroy
        end

        it "stop" do
          cs = Model::Generator.control_system.save!
          mod = Model::Generator.module(control_system: cs)
          mod.running = true
          mod.save!
          cs.update_fields(modules: [mod.id.not_nil!])

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
          Model::Module.find!(mod.id.not_nil!).running.should be_false

          mod.destroy
          cs.destroy
        end
      end

      describe "CRUD operations" do
        test_crd(klass: Model::ControlSystem, controller_klass: Systems)

        describe "update" do
          it "if version is valid" do
            cs = Model::Generator.control_system.save!
            cs.persisted?.should be_true

            original_name = cs.name
            cs.name = Faker::Hacker.noun

            id = cs.id.not_nil!

            params = HTTP::Params.encode({"version" => "0"})
            path = "#{base + id}?#{params}"

            result = curl(
              method: "PATCH",
              path: path,
              body: cs.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status_code.should eq 200
            updated = Model::ControlSystem.from_json(result.body)
            updated.id.should eq cs.id
            updated.name.should_not eq original_name
          end

          it "fails when version is invalid" do
            cs = Model::Generator.control_system.save!
            id = cs.id.not_nil!
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
