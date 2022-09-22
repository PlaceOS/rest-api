require "../helper"

module PlaceOS::Api
  describe Users do
    Spec.test_404(Users.base_route, model_name: Model::User.table_name, headers: Spec::Authentication.headers)

    describe "CRUD operations", tags: "crud" do
      it "query via email" do
        model = Model::Generator.user.save!
        model.persisted?.should be_true
        id = model.id.as(String)

        params = HTTP::Params.encode({"q" => model.email.to_s})
        path = "#{Users.base_route}?#{params}"

        sleep 2

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
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
        result = client.get(
          path: File.join(Users.base_route, id),
          headers: Spec::Authentication.headers,
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
        result = client.get(
          path: Users.base_route + model.email.to_s,
          headers: Spec::Authentication.headers,
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
        result = client.get(
          path: Users.base_route + login,
          headers: Spec::Authentication.headers,
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
        result = client.get(
          path: Users.base_route + staff_id,
          headers: Spec::Authentication.headers,
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
          result = client.patch(
            path: File.join(Users.base_route, id),
            body: {groups: updated_groups}.to_json,
            headers: Spec::Authentication.headers
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id
          response_model.groups.should eq updated_groups

          model.destroy
        end
      end
    end

    describe "GET /users/current" do
      it "renders the current user" do
        result = client.get(
          path: File.join(Users.base_route, "/current"),
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        response_user = Model::User.from_trusted_json(result.body)
        response_user.id.should eq Spec::Authentication.user.id
      end
    end

    describe "GET /users/:id/metadata" do
      it "shows user metadata" do
        user = Model::Generator.user.save!
        user_id = user.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: user_id).save!

        result = client.get(
          path: Users.base_route + "#{user_id}/metadata",
          headers: Spec::Authentication.headers,
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
      Spec.test_controller_scope(Users)
    end
  end
end
