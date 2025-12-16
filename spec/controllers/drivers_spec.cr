require "../helper"

module PlaceOS::Api
  describe Drivers, tags: "drivers" do
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
    end

    describe "readme" do
      it "returns the readme content for a driver" do
        # Create a repository pointing to the real PlaceOS/drivers repo
        repository = Model::Generator.repository(type: Model::Repository::Type::Driver)
        repository.uri = "https://github.com/PlaceOS/drivers"
        repository.save!

        # Create a driver with a real file path that has a readme
        driver = Model::Driver.new(
          name: "Auto Release",
          role: Model::Driver::Role::Logic,
          commit: "HEAD",
          module_name: "AutoRelease",
          file_name: "drivers/place/auto_release.cr",
        )
        driver.repository = repository
        driver.save!

        id = driver.id.as(String)
        path = File.join(Drivers.base_route, id, "readme")

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true
        result.body.should contain("Auto Release")
      end

      it "returns 404 when readme does not exist" do
        # Create a repository pointing to the real PlaceOS/drivers repo
        repository = Model::Generator.repository(type: Model::Repository::Type::Driver)
        repository.uri = "https://github.com/PlaceOS/drivers"
        repository.save!

        # Create a driver with a file path that does NOT have a readme
        driver = Model::Driver.new(
          name: "No Readme Driver",
          role: Model::Driver::Role::Logic,
          commit: "HEAD",
          module_name: "NoReadme",
          file_name: "drivers/place/nonexistent_driver.cr",
        )
        driver.repository = repository
        driver.save!

        id = driver.id.as(String)
        path = File.join(Drivers.base_route, id, "readme")

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 404
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
