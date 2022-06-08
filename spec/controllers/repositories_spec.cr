require "../helper"

module PlaceOS::Api
  describe Repositories do
    _authenticated_user, authorization_header = authentication

    Specs.test_404(Repositories.base_route, model_name: Model::Repository.table_name, headers: authorization_header)

    describe "index", tags: "search" do
      Specs.test_base_index(Model::Repository, Repositories)
    end

    describe "CRUD operations", tags: "crud" do
      Specs.test_crd(Model::Repository, Repositories)

      it "update" do
        repository = Model::Generator.repository.save!
        original_name = repository.name
        repository.name = random_name

        id = repository.id.as(String)
        path = File.join(Repositories.base_route, id)
        result = client.patch(
          path: path,
          body: repository.changed_attributes.to_json,
          headers: authorization_header,
        )

        result.status_code.should eq 200
        updated = Model::Repository.from_trusted_json(result.body)

        updated.id.should eq repository.id
        updated.name.should_not eq original_name
      end

      describe "mutating URIs" do
        it "does not update Driver repositories with modified URIs" do
          repository = Model::Generator.repository(type: Model::Repository::Type::Driver).save!

          id = repository.id.as(String)
          path = File.join(Repositories.base_route, id)
          result = client.patch(
            path: path,
            body: {uri: "https://changed:8080"}.to_json,
            headers: authorization_header,
          )

          result.status_code.should eq 422
        end

        it "does update Interface repositories with modified URIs" do
          repository = Model::Generator.repository(type: Model::Repository::Type::Interface).save!

          id = repository.id.as(String)
          path = File.join(Repositories.base_route, id)
          result = client.patch(
            path: path,
            body: {uri: "https://changed:8080"}.to_json,
            headers: authorization_header,
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
          path = "#{Repositories.base_route}#{id}/drivers"
          result = client.get(
            path: path,
            headers: authorization_header,
          )

          result.status.should eq HTTP::Status::BAD_REQUEST
        end

        it "errors when requesting driver details from an interface repo" do
          id = repo.id.as(String)
          path = "#{Repositories.base_route}#{id}/details"
          result = client.get(
            path: path,
            headers: authorization_header,
          )

          result.status.should eq HTTP::Status::BAD_REQUEST
        end
      end
    end

    describe "GET /:id/commits" do
      context "interface" do
        pending "fetches the commits for a repository" do
        end
      end

      context "driver" do
        repo = Model::Generator.repository(type: :driver).tap do |r|
          r.uri = "https://github.com/placeOS/private-drivers"
        end

        before_all do
          repo.save!
        end

        pending "fetches commits for a repository" do
          id = repo.id.as(String)
          response = client.get("#{Repositories.base_route}#{id}/commits?#{HTTP::Params{"id" => id}}")
          response.status.should eq HTTP::Status::OK
          Array(String).from_json(response.body).should_not be_empty
        end

        pending "fetches commits for a file" do
          id = repo.id.as(String)
          response = client.get("#{Repositories.base_route}#{id}/commits?#{HTTP::Params{"driver" => "drivers/place/private_helper.cr", "id" => id}}")
          response.status.should eq HTTP::Status::OK
          Array(String).from_json(response.body).should_not be_empty
        end
      end
    end

    describe "scopes" do
      Specs.test_controller_scope(Repositories)
      Specs.test_update_write_scope(Repositories)
    end
  end
end
