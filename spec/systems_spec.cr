require "./helper"

module Engine::API
  describe Systems do
    with_server do
      test_404(namespace: Systems::NAMESPACE, model_name: Model::ControlSystem.table_name)

      pending "index"

      describe "CRUD operations" do
        test_crd(klass: Model::ControlSystem, controller_klass: Systems)

        describe "update" do
          pending "updates when version is valid" do
            cs = Model::Generator.control_system.save!
            cs.name = Faker::Hacker.name

            id = cs.id.not_nil!

            params = HTTP::Params.encode({"version" => "0"})
            path = "#{Systems::NAMESPACE[0] + id}/?#{params}"

            result = curl(
              method: "PATCH",
              path: path,
              body: cs.to_json,
              headers: {"Content-Type" => "application/json"},
            )

            result.success?.should be_true
            updated = Model::ControlSystem.from_trusted_json(result.body)
            updated.attributes.should eq cs.attributes
          end

          pending "fails when version is invalid"
        end
      end
    end
  end
end
