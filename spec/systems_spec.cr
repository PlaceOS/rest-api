require "./helper"

module Engine::API
  describe Systems do
    with_server do
      test_404(namespace: Systems::NAMESPACE, model_name: Model::ControlSystem.table_name)

      pending "index"

      describe "remove" do
        pending "removes module if not in use by another ControlSystem"
        pending "keeps module if in use by another ControlSystem"
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

          path = Systems::NAMESPACE[0] + "#{cs.id}/start"

          result = curl(
            method: "POST",
            path: path,
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

          path = Systems::NAMESPACE[0] + "#{cs.id}/stop"

          result = curl(
            method: "POST",
            path: path,
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
            path = "#{Systems::NAMESPACE[0] + id}?#{params}"

            result = curl(
              method: "PATCH",
              path: path,
              body: cs.to_json,
              headers: {"Content-Type" => "application/json"},
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
            path = "#{Systems::NAMESPACE[0] + id}?#{params}"

            result = curl(
              method: "PATCH",
              path: path,
              body: cs.to_json,
              headers: {"Content-Type" => "application/json"},
            )

            result.status_code.should eq 409
          end
        end
      end
    end
  end
end
