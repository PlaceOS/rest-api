require "./helper"

module Engine::API
  describe Drivers do
    with_server do
      pending "index" do
        test_base_index(klass: Model::Driver, controller_klass: Drivers)
        it "filters queries by driver role" do
          service = Model::Generator.driver(role: Model::Driver::Role::Service)
          service.name = Faker::Hacker.noun + rand((1..10000)).to_s
          service.save!

          sleep 10

          params = HTTP::Params.encode({
            "role" => Model::Driver::Role::Service.to_i.to_s,
            "q"    => service.id.not_nil!,
          })

          path = "#{Drivers::NAMESPACE[0]}?#{params}"

          result = curl(
            method: "GET",
            path: path,
          )

          result.status_code.should eq 200
          results = JSON.parse(result.body)["results"].as_a

          all_service_roles = results.all? { |result| result["role"] == Model::Driver::Role::Service.to_i }
          contains_search_term = results.any? { |result| result["id"] == service.id }

          all_service_roles.should be_true
          contains_search_term.should be_true
        end
      end

      test_404(namespace: Drivers::NAMESPACE, model_name: Model::Driver.table_name)

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
