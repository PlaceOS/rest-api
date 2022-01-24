require "../helper"
require "../core_helper"

# require "placeos-compiler"

module PlaceOS::Api
  describe Drivers do
    _, authorization_header = authentication
    base = Drivers::NAMESPACE[0]

    with_server do
      describe "index", tags: "search" do
        test_base_index(klass: Model::Driver, controller_klass: Drivers)

        it "filters queries by driver role" do
          service = Model::Generator.driver(role: Model::Driver::Role::Service)
          service.name = random_name
          service.save!

          params = HTTP::Params.encode({
            "role" => Model::Driver::Role::Service.to_i.to_s,
            "q"    => service.name,
          })

          refresh_elastic(Model::Driver.table_name)
          path = "#{base}?#{params}"
          found = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body)
            all_service_roles = results.all? { |r| r["role"] == Model::Driver::Role::Service.to_i }
            contains_search_term = results.any? { |r| r["id"] == service.id }
            !results.empty? && all_service_roles && contains_search_term
          end

          found.should be_true
        end
      end

      test_404(base, model_name: Model::Driver.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        before_each do
          HttpMocks.etcd_range
          HttpMocks.core_compiled
        end

        test_crd(klass: Model::Driver, controller_klass: Drivers)

        describe "update" do
          it "if role is preserved" do
            driver = Model::Generator.driver.save!
            original_name = driver.name
            driver.name = random_name

            id = driver.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.changed_attributes.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )
            result.success?.should be_true

            updated = Model::Driver.from_trusted_json(result.body)
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
              body: driver.changed_attributes.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.success?.should_not be_true
            result.body.should contain "role must not change"
          end
        end

        it "GET /:id/compiled" do
          driver = Model::Generator.driver.save!

          response = curl(
            method: "GET",
            path: "#{base}#{driver.id.not_nil!}/compiled",
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          response.success?.should be_true
        end
      end

      it "POST /:id/recompile" do
        driver, _, _, _ = setup_system

        response = curl(
          method: "POST",
          path: "#{base}#{driver.id.not_nil!}/recompile",
          headers: authorization_header.merge({"Content-Type" => "application/json"}),
        )

        response.success?.should be_true
        updated = Model::Driver.from_trusted_json(response.body)
        updated.commit.starts_with?("RECOMPILE").should be_false
      end

      describe "scopes" do
        before_each do
          HttpMocks.etcd_range
          HttpMocks.core_compiled
        end

        test_controller_scope(Drivers)
      end
    end
  end
end
