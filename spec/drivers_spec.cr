require "./helper"

module Engine::API
  describe Drivers do
    with_server do
      test_404(namespace: Drivers::NAMESPACE, model_name: Model::Driver.table_name)

      pending "index"

      describe "CRUD operations" do
        test_crd(klass: Model::Driver, controller_klass: Drivers)

        describe "update" do
          it "if role is preserved" do
            driver = Model::Generator.driver.save!
            original_name = driver.name
            driver.name = Faker::Hacker.noun

            id = driver.id.not_nil!
            path = Drivers::NAMESPACE[0] + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.to_json,
              headers: {"Content-Type" => "application/json"},
            )
            result.success?.should be_true

            updated = Model::Driver.from_json(result.body)
            updated.id.should eq driver.id
            updated.name.should_not eq original_name
          end

          it "fails if role differs" do
            driver = Model::Generator.driver(role: Model::Driver::Role::SSH).save!
            driver.role = Model::Driver::Role::Device
            id = driver.id.not_nil!
            path = Drivers::NAMESPACE[0] + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.to_json,
              headers: {"Content-Type" => "application/json"},
            )

            result.success?.should_not be_true
            result.body.should contain "role must not change"
          end
        end
      end
    end
  end
end
