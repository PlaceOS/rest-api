require "../helper"

module PlaceOS::Api
  describe Repositories do
    Spec.test_404(Repositories.base_route, model_name: Model::Repository.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::Repository, Repositories)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::Repository, Repositories)

      it "update" do
        repository = Model::Generator.repository.save!
        original_name = repository.name
        repository.name = random_name

        id = repository.id.as(String)
        path = File.join(Repositories.base_route, id)
        result = client.patch(
          path: path,
          body: repository.changed_attributes.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::Repository.from_trusted_json(result.body)

        updated.id.should eq repository.id
        updated.name.should_not eq original_name
      end

      describe "mutating URIs" do
        it "does update Driver repositories with modified URIs" do
          repository = Model::Generator.repository(type: Model::Repository::Type::Driver).save!

          id = repository.id.as(String)
          path = File.join(Repositories.base_route, id)
          result = client.patch(
            path: path,
            body: {uri: "https://changed:8080"}.to_json,
            headers: Spec::Authentication.headers,
          )

          result.status_code.should eq 200
        end

        it "does update Interface repositories with modified URIs" do
          repository = Model::Generator.repository(type: Model::Repository::Type::Interface).save!

          id = repository.id.as(String)
          path = File.join(Repositories.base_route, id)
          result = client.patch(
            path: path,
            body: {uri: "https://changed:8080"}.to_json,
            headers: Spec::Authentication.headers,
          )

          result.status_code.should eq 200
        end
      end

      describe "driver only actions" do
        repo = Model::Generator.repository(type: :interface)
        before_all do
          repo.save!
        end

        it "errors if enumerating drivers in an interface repo" do
          id = repo.id.as(String)
          path = File.join(Repositories.base_route, "#{id}/drivers")
          result = client.get(
            path: path,
            headers: Spec::Authentication.headers,
          )

          result.status.should eq HTTP::Status::BAD_REQUEST
        end

        it "errors when requesting driver details from an interface repo" do
          id = repo.id.as(String)
          path = File.join(Repositories.base_route, "#{id}/details")
          result = client.get(
            path: path,
            headers: Spec::Authentication.headers,
          )

          result.status.should eq HTTP::Status::BAD_REQUEST
        end
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Repositories)
      Spec.test_update_write_scope(Repositories)
    end
  end
end
