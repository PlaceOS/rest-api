require "./helper"

module Engine::API
  describe Systems do
    with_server do
      test_404(namespace: Systems::NAMESPACE, model_name: Model::ControlSystem.table_name)

      pending "index"
      pending "remove"

      pending "count"
      pending "types"

      pending "start"
      pending "stop"
      pending "exec"

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
