require "./helper"

module Engine::API
  describe Drivers do
    with_server do
      test_404(namespace: Drivers::NAMESPACE, model_name: Model::Driver.table_name)
      pending "index"
      describe "CRUD operations" do
        test_crd(klass: Model::Driver, controller_klass: Drivers)
        describe "update" do
          pending "updates" do
            driver = Model::Generator.driver.save!
            driver.name = Faker::Hacker.name

            id = driver.id.not_nil!
            path = Drivers::NAMESPACE[0] + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.to_json,
              headers: {"Content-Type" => "application/json"},
            )

            result.success?.should be_true
            updated = Model::Driver.from_trusted_json(result.body)
            updated.attributes.should eq driver.attributes
          end

          pending "fails if role differs"
        end
      end
    end
  end
end
