require "../helper"

module PlaceOS::Api
  describe AssetCategories do
    Spec.test_404(AssetCategories.base_route, model_name: Model::AssetCategory.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AssetCategory, AssetCategories)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetCategory, AssetCategories)
      Spec.test_crd(Model::AssetCategory, AssetCategories, sys_admin: false, support: false, groups: ["management"])
      Spec.test_crd(Model::AssetCategory, AssetCategories, sys_admin: false, support: false, groups: ["concierge"])

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.asset_category.to_json
        result = client.post(
          AssetCategories.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetCategories)
    end

    describe "support-subsystem permissions" do
      ::Spec.before_each { clear_group_tables }

      it "allows POST for a support user with Create on the org zone (both sides)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Create).save!

        body = Model::Generator.asset_category.to_json
        result = client.post(AssetCategories.base_route, body: body, headers: headers)
        result.status_code.should eq 201

        Model::AssetCategory.from_trusted_json(result.body).destroy
      end

      it "rejects POST when the support user only has Read on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Read).save!

        body = Model::Generator.asset_category.to_json
        result = client.post(AssetCategories.base_route, body: body, headers: headers)
        result.status_code.should eq 403
      end

      it "requires Update on both sides to PATCH an asset category" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        asset_category = Model::Generator.asset_category.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Update).save!

        result = client.patch(
          path: "#{AssetCategories.base_route}#{asset_category.id}",
          body: {name: "renamed-#{random_name}"}.to_json,
          headers: headers,
        )
        result.success?.should be_true
        asset_category.destroy
      end

      it "rejects PATCH when the support user only has Create on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        asset_category = Model::Generator.asset_category.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Create).save!

        result = client.patch(
          path: "#{AssetCategories.base_route}#{asset_category.id}",
          body: {name: "renamed-#{random_name}"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
        asset_category.destroy
      end

      it "requires Delete on both sides to DELETE an asset category" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        asset_category = Model::Generator.asset_category.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Delete).save!

        result = client.delete(path: "#{AssetCategories.base_route}#{asset_category.id}", headers: headers)
        result.success?.should be_true
        Model::AssetCategory.find?(asset_category.id).should be_nil
      end

      it "rejects DELETE when the support user only has Update on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        asset_category = Model::Generator.asset_category.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Update).save!

        result = client.delete(path: "#{AssetCategories.base_route}#{asset_category.id}", headers: headers)
        result.status_code.should eq 403
        asset_category.destroy
      end

      it "allows a support-JWT user to POST regardless of group grants" do
        body = Model::Generator.asset_category.to_json
        result = client.post(
          AssetCategories.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 201
        Model::AssetCategory.from_trusted_json(result.body).destroy
      end

      it "allows an admin-JWT user to POST regardless of group grants" do
        body = Model::Generator.asset_category.to_json
        result = client.post(
          AssetCategories.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: true, support: false),
        )
        result.status_code.should eq 201
        Model::AssetCategory.from_trusted_json(result.body).destroy
      end
    end
  end
end
