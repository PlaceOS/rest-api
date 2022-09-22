require "../helper"

module PlaceOS::Api
  describe Drivers do
    describe "index", tags: "search" do
      Spec.test_base_index(klass: Model::Driver, controller_klass: Drivers)

      it "filters queries by driver role" do
        service = Model::Generator.driver(role: Model::Driver::Role::Service)
        service.name = random_name
        service.save!

        params = HTTP::Params.encode({
          "role" => Model::Driver::Role::Service.to_i.to_s,
          "q"    => service.name,
        })

        refresh_elastic(Model::Driver.table_name)
        path = "#{Drivers.base_route}?#{params}"
        found = until_expected("GET", path, Spec::Authentication.headers) do |response|
          results = Array(Hash(String, JSON::Any)).from_json(response.body)
          all_service_roles = results.all? { |r| r["role"] == Model::Driver::Role::Service.to_i }
          contains_search_term = results.any? { |r| r["id"] == service.id }
          !results.empty? && all_service_roles && contains_search_term
        end

        found.should be_true
      end
    end

    Spec.test_404(Drivers.base_route, model_name: Model::Driver.table_name, headers: Spec::Authentication.headers)

    describe "CRUD operations", tags: "crud" do
      before_each do
        HttpMocks.reset
      end

      Spec.test_crd(klass: Model::Driver, controller_klass: Drivers)

      describe "update" do
        it "if role is preserved" do
          driver = Model::Generator.driver.save!
          original_name = driver.name
          driver.name = random_name

          id = driver.id.as(String)
          path = File.join(Drivers.base_route, id)
          result = client.patch(
            path: path,
            body: driver.changed_attributes.to_json,
            headers: Spec::Authentication.headers,
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
          path = File.join(Drivers.base_route, id)
          result = client.patch(
            path: path,
            body: driver.changed_attributes.to_json,
            headers: Spec::Authentication.headers,
          )

          result.success?.should_not be_true
          result.body.should contain "role must not change"
        end
      end

      it "POST /:id/recompile" do
        driver = get_driver
        path = File.join(Drivers.base_route, "#{driver.id.not_nil!}/recompile")
        response = client.post(
          path: path,
          headers: Spec::Authentication.headers,
        )

        response.success?.should be_true
        updated = Model::Driver.from_trusted_json(response.body)
        updated.commit.starts_with?("RECOMPILE").should be_false
      end
    end

    describe "scopes" do
      before_each do
        HttpMocks.core_compiled
      end

      Spec.test_controller_scope(Drivers)
    end
  end
end
