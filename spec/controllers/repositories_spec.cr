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

        it "should work with changefeeds" do
          result = nil
          spawn do
            result = PlaceOS::Api::Repositories.pull_repository(repo, 10.seconds)
          end

          sleep 1.second
          repo.reload!
          repo.deployed_commit_hash.should be_nil
          repo.deployed_commit_hash = "123456"
          repo.save!

          sleep 1.second
          result.should_not be_nil
          if output = result
            output[1].should eq "123456"
          end
        end
      end
    end

    describe "files" do
      describe ".match_files" do
        files = [
          "index.html",
          "README.md",
          "result/folder/file.html",
          "result/folder/file.htm",
          "dist/app.html",
          "dist/nested/page.html",
          "dist/app.js",
        ]

        it "matches file names at any depth when the pattern has no slash" do
          Repositories.match_files(files, "*.html", "plugins").should eq [
            "/plugins/index.html",
            "/plugins/result/folder/file.html",
            "/plugins/dist/app.html",
            "/plugins/dist/nested/page.html",
          ]
        end

        it "matches the full path when the pattern has a slash" do
          Repositories.match_files(files, "dist/*.html", "plugins").should eq ["/plugins/dist/app.html"]
          Repositories.match_files(files, "/dist/**/*.html", "plugins").should eq [
            "/plugins/dist/app.html",
            "/plugins/dist/nested/page.html",
          ]
        end

        it "only lists files under the root path, relative to it" do
          Repositories.match_files(files, "*.html", "plugins", "/dist/").should eq [
            "/plugins/app.html",
            "/plugins/nested/page.html",
          ]
        end

        it "returns an empty array when nothing matches" do
          Repositories.match_files(files, "*.css", "plugins").should be_empty
        end
      end

      it "errors if listing files in a driver repo" do
        repo = Model::Generator.repository(type: Model::Repository::Type::Driver).save!
        result = client.get(
          path: File.join(Repositories.base_route, "#{repo.id}/files?pattern=*.cr"),
          headers: Spec::Authentication.headers,
        )
        result.status.should eq HTTP::Status::BAD_REQUEST
      end

      it "lists matching files in an interface repo, joined to the folder name" do
        repo = Model::Generator.repository(type: Model::Repository::Type::Interface)
        repo.uri = "https://github.com/PlaceOS/drivers"
        repo.branch = "master"
        repo.folder_name = "plugins-#{random_id}"
        repo.save!

        result = client.get(
          path: File.join(Repositories.base_route, "#{repo.id}/files?pattern=*_readme.md"),
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200

        files = Array(String).from_json(result.body)
        files.should contain "/#{repo.folder_name}/drivers/place/auto_release_readme.md"
        files.all? { |file| file.starts_with?("/#{repo.folder_name}/") && file.ends_with?("_readme.md") }.should be_true
      end

      it "lists files relative to the root path" do
        repo = Model::Generator.repository(type: Model::Repository::Type::Interface)
        repo.uri = "https://github.com/PlaceOS/drivers"
        repo.branch = "master"
        repo.folder_name = "plugins-#{random_id}"
        repo.root_path = "drivers/place"
        repo.save!

        result = client.get(
          path: File.join(Repositories.base_route, "#{repo.id}/files?pattern=auto_release*"),
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200

        files = Array(String).from_json(result.body)
        files.should contain "/#{repo.folder_name}/auto_release_readme.md"
        files.should contain "/#{repo.folder_name}/auto_release.cr"
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Repositories)
      Spec.test_update_write_scope(Repositories)
    end
  end
end
