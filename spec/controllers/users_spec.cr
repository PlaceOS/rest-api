require "../helper"

module PlaceOS::Api
  describe Users do
    Spec.test_404(Users.base_route, model_name: Model::User.table_name, headers: Spec::Authentication.headers)

    describe "CRUD operations", tags: "crud" do
      it "query via email" do
        model = Model::Generator.user.save!
        model.persisted?.should be_true
        id = model.id.as(String)

        params = HTTP::Params.encode({"q" => model.email.to_s, "fields" => "email,"})
        path = "#{Users.base_route}?#{params}"

        sleep 2.seconds

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

        it "does not allow email to be updated" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true
          original_email = model.email.to_s

          id = model.id.as(String)
          result = client.patch(
            path: File.join(Users.base_route, id),
            body: {email: "changed@example.com", name: "Updated Name"}.to_json,
            headers: Spec::Authentication.headers
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id
          response_model.email.to_s.should eq original_email
          response_model.name.should eq "Updated Name"

          model.destroy
        end

        it "does not allow last_login, login_count, or logged_out_at to be updated" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true

          original_login_count = model.login_count
          original_last_login = model.last_login
          original_logged_out_at = model.logged_out_at

          id = model.id.as(String)
          result = client.patch(
            path: File.join(Users.base_route, id),
            body: {
              login_count:   999,
              last_login:    Time.utc.to_unix,
              logged_out_at: Time.utc.to_rfc3339,
              name:          "Still Updated",
            }.to_json,
            headers: Spec::Authentication.headers
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id
          response_model.login_count.should eq original_login_count
          response_model.last_login.should eq original_last_login
          response_model.logged_out_at.should eq original_logged_out_at
          response_model.name.should eq "Still Updated"

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

    describe "support subsystem permissions" do
      ::Spec.before_each { clear_group_tables }

      it "allows a support-subsystem user with Create grant to POST /users" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Create).save!

        new_user = Model::Generator.user(authority)
        result = client.post(
          path: Users.base_route,
          body: new_user.to_json,
          headers: headers,
        )
        result.status_code.should eq 201

        created = Model::User.from_trusted_json(result.body)
        created.authority_id.should eq authority.id
        Model::User.find?(created.id.as(String)).should_not be_nil
        created.destroy
      end

      it "rejects POST /users for a regular user without a support grant" do
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        new_user = Model::Generator.user(authority)
        result = client.post(
          path: Users.base_route,
          body: new_user.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
      end

      it "rejects POST /users when the user-side has the bit but no GroupZone reach" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        # No GroupZone on the org zone — AND semantics deny.

        new_user = Model::Generator.user(authority)
        result = client.post(
          path: Users.base_route,
          body: new_user.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
      end

      it "allows a support-subsystem user with Delete grant to DELETE a user" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Delete).save!

        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, target_id),
          headers: headers,
        )
        result.success?.should be_true
        Model::User.find?(target_id).should be_nil
      end

      it "rejects DELETE for a support-subsystem user holding only Create (not Delete)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Create).save!

        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, target_id),
          headers: headers,
        )
        result.status_code.should eq 403

        target.destroy
      end

      it "allows a support-subsystem user with Update grant to update another user" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Update).save!

        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.patch(
          path: File.join(Users.base_route, target_id),
          body: {name: "Support Updated"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 200
        Model::User.from_trusted_json(result.body).name.should eq "Support Updated"

        target.destroy
      end

      it "allows the self-update path without any support grant" do
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        user_id = user.id.as(String)

        result = client.patch(
          path: File.join(Users.base_route, user_id),
          body: {name: "Self Updated"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 200
        Model::User.from_trusted_json(result.body).name.should eq "Self Updated"
      end

      it "rejects updating another user with neither self, admin, nor a support grant" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.patch(
          path: File.join(Users.base_route, target_id),
          body: {name: "Should Fail"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403

        target.destroy
      end

      it "keeps resource-token routes admin-only (support subsystem denied)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        # Full Manage support grant — still must not reach resource-token routes.
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Manage).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Manage).save!

        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, target_id, "resource_token"),
          headers: headers,
        )
        result.status_code.should eq 403

        target.destroy
      end

      it "keeps resource-token routes admin-only (support JWT denied)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, target_id, "resource_token"),
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 403

        target.destroy
      end

      it "allows admins to use the delete resource-token route" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.user(authority).save!
        target_id = target.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, target_id, "resource_token"),
          headers: Spec::Authentication.headers(sys_admin: true),
        )
        result.status_code.should eq 202

        target.destroy
      end

      it "allows a support JWT to create and destroy users (role bypass)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        support_headers = Spec::Authentication.headers(sys_admin: false, support: true)

        new_user = Model::Generator.user(authority)
        result = client.post(
          path: Users.base_route,
          body: new_user.to_json,
          headers: support_headers,
        )
        result.status_code.should eq 201
        created = Model::User.from_trusted_json(result.body)
        created_id = created.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, created_id),
          headers: support_headers,
        )
        result.success?.should be_true
        Model::User.find?(created_id).should be_nil
      end

      it "allows an admin JWT to create and destroy users (role bypass)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        admin_headers = Spec::Authentication.headers(sys_admin: true)

        new_user = Model::Generator.user(authority)
        result = client.post(
          path: Users.base_route,
          body: new_user.to_json,
          headers: admin_headers,
        )
        result.status_code.should eq 201
        created = Model::User.from_trusted_json(result.body)
        created_id = created.id.as(String)

        result = client.delete(
          path: File.join(Users.base_route, created_id),
          headers: admin_headers,
        )
        result.success?.should be_true
        Model::User.find?(created_id).should be_nil
      end
    end

    describe "GET /metadata/search" do
      it "renders the JSON path search results" do
        schema = <<-J
        { "address": {
            "city":"Sydney",
            "street": "Some street, 7A"
        },
        "lift": false,
        "floor": [
          {
            "level": 1,
            "apt": [
                        {"no": 1, "area": 40, "rooms": 1},
                        {"no": 2, "area": 80, "rooms": 3},
                        {"no": 3, "area": 50, "rooms": 2}
            ]
          },
          {
            "level": 2,
            "apt": [
                        {"no": 4, "area": 100, "rooms": 3},
                        {"no": 5, "area": 60, "rooms": 2}
            ]
          }
        ]
      }
      J
        user = Model::Generator.user.save!
        user_id = user.id
        name = random_name
        metadata = Model::Generator.metadata(name: name, parent: user_id)
        metadata.details = JSON.parse(schema)
        metadata.save!

        filters = [
          # Search for any string that contains the value of "Sydney"
          %($.** ? (@ == "Sydney")),
          # Search for any apartment on any floor with the area from 40 to 90
          %($.floor[*].apt[*] ? (@.area > 40 && @.area < 90)),
          # Search for apartments with the number greater than 3
          %($.floor.apt.no ? (@>3)),
        ]

        filters.each do |filter|
          resp = client.get(
            path: "#{Users.base_route}metadata/search?filter=#{URI.encode_path_segment(filter)}",
            headers: Spec::Authentication.headers,
          )

          resp.status_code.should eq 200
          users = Array(Model::User).from_json(resp.body)
          users.size.should eq(1)
          users.first.id.should eq(user_id)

          resp.headers["X-Total-Count"].should eq("1")
          resp.headers["Link"]?.should be_nil
        end
      end
    end
  end
end
