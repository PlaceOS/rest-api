require "./helper"

module PlaceOS::Api
  describe Drivers do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Drivers::NAMESPACE[0]

    with_server do
      describe "index", tags: "search" do
        test_base_index(klass: Model::Driver, controller_klass: Drivers)
        it "filters queries by driver role" do
          service = Model::Generator.driver(role: Model::Driver::Role::Service)
          service.name = Faker::Hacker.noun + rand((1..10000)).to_s
          service.save!

          sleep 1

          params = HTTP::Params.encode({
            "role" => Model::Driver::Role::Service.to_i.to_s,
            "q"    => service.id.as(String),
          })

          path = "#{base}?#{params}"
          found = until_expected("GET", path, authorization_header) do |response|
            results = JSON.parse(response.body).as_a
            all_service_roles = results.all? { |r| r["role"] == Model::Driver::Role::Service.to_i }
            contains_search_term = results.any? { |r| r["id"] == service.id }
            all_service_roles && contains_search_term
          end

          found.should be_true
        end
      end

      test_404(base, model_name: Model::Driver.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Driver, controller_klass: Drivers)

        describe "update" do
          it "if role is preserved" do
            driver = Model::Generator.driver.save!
            original_name = driver.name
            driver.name = Faker::Hacker.noun

            id = driver.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )
            result.success?.should be_true

            updated = Model::Driver.from_json(result.body)
            updated.id.should eq driver.id
            updated.name.should_not eq original_name
          end

          it "fails if role differs" do
            driver = Model::Generator.driver(role: Model::Driver::Role::SSH).save!
            driver.role = Model::Driver::Role::Device
            id = driver.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.success?.should_not be_true
            result.body.should contain "role must not change"
          end
        end
      end
    end
  end
end
