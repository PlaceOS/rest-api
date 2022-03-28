require "../helper"

module PlaceOS::Api
  describe Users do
    authenticated_user, authorization_header = authentication
    base = Users::NAMESPACE[0]

    with_server do
      Specs.test_404(base, model_name: Model::User.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        it "query via email" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true
          id = model.id.as(String)

          params = HTTP::Params.encode({"q" => model.email.to_s})
          path = "#{base}?#{params}"

          sleep 2

          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response = Array(Model::User).from_json(result.body)
          response.size.should eq 1
          response.first.id.should eq id
        end

        it "show" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true
          id = model.id.as(String)
          result = curl(
            method: "GET",
            path: base + id,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id

          model.destroy
        end

        it "show via email" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true
          id = model.id.as(String)
          result = curl(
            method: "GET",
            path: base + model.email.to_s,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id
          response_model.email.should eq model.email

          model.destroy
        end

        it "show via login_name" do
          login = random_name
          model = Model::Generator.user
          model.login_name = login
          model.save!
          model.persisted?.should be_true
          id = model.id.as(String)
          result = curl(
            method: "GET",
            path: base + login,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id

          model.destroy
        end

        it "show via staff_id" do
          staff_id = "12345678"
          model = Model::Generator.user
          model.staff_id = staff_id
          model.save!
          model.persisted?.should be_true
          id = model.id.as(String)
          result = curl(
            method: "GET",
            path: base + staff_id,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id

          model.destroy
        end

        describe "update" do
          it "updates groups" do
            initial_groups = ["public"]

            model = Model::Generator.user
            model.groups = initial_groups
            model.save!
            model.persisted?.should be_true

            updated_groups = ["admin", "public", "calendar"]

            id = model.id.as(String)
            result = curl(
              method: "PATCH",
              path: base + id,
              body: {groups: updated_groups}.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"})
            )

            result.status_code.should eq 200
            response_model = Model::User.from_trusted_json(result.body)
            response_model.id.should eq id
            response_model.groups.should eq updated_groups

            model.destroy
          end
        end
      end

      describe "/current" do
        it "renders the current user" do
          authenticated_user, authorization_header = authentication
          result = curl(
            method: "GET",
            path: File.join(base, "/current"),
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_user = Model::User.from_trusted_json(result.body)
          response_user.id.should eq authenticated_user.id
        end
      end

      describe "/:id/metadata" do
        it "shows user metadata" do
          user = Model::Generator.user.save!
          user_id = user.id.as(String)
          meta = Model::Generator.metadata(name: "special", parent: user_id).save!

          result = curl(
            method: "GET",
            path: base + "#{user_id}/metadata",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
          metadata.first[1].parent_id.should eq user_id
          metadata.first[1].name.should eq meta.name

          user.destroy
          meta.destroy
        end
      end

      describe "scopes" do
        Specs.test_controller_scope(Users)
      end
    end
  end
end
