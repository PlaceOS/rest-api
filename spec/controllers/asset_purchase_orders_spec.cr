require "../helper"

module PlaceOS::Api
  describe AssetPurchaseOrders do
    Spec.test_404(AssetPurchaseOrders.base_route, model_name: Model::AssetPurchaseOrder.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      it "queries AssetPurchaseOrder", tags: "search" do
        _, headers = Spec::Authentication.authentication
        doc = PlaceOS::Model::Generator.asset_purchase_order
        purchase_order_number = random_name
        doc.purchase_order_number = purchase_order_number
        doc.save!

        refresh_elastic(Model::AssetPurchaseOrder.table_name)

        doc.persisted?.should be_true
        params = HTTP::Params.encode({"q" => purchase_order_number})
        path = "#{AssetPurchaseOrders.base_route.rstrip('/')}?#{params}"

        found = until_expected("GET", path, headers) do |response|
          Array(Hash(String, JSON::Any))
            .from_json(response.body)
            .map(&.["id"].to_s)
            .any?(doc.id)
        end
        found.should be_true
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetPurchaseOrder, AssetPurchaseOrders)
      Spec.test_crd(Model::AssetPurchaseOrder, AssetPurchaseOrders, sys_admin: false, support: false, groups: ["management"])
      Spec.test_crd(Model::AssetPurchaseOrder, AssetPurchaseOrders, sys_admin: false, support: false, groups: ["concierge"])

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.asset_purchase_order.to_json
        result = client.post(
          AssetPurchaseOrders.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetPurchaseOrders)
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

        body = Model::Generator.asset_purchase_order.to_json
        result = client.post(AssetPurchaseOrders.base_route, body: body, headers: headers)
        result.status_code.should eq 201

        Model::AssetPurchaseOrder.from_trusted_json(result.body).destroy
      end

      it "rejects POST when the support user only has Read on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Read).save!

        body = Model::Generator.asset_purchase_order.to_json
        result = client.post(AssetPurchaseOrders.base_route, body: body, headers: headers)
        result.status_code.should eq 403
      end

      it "requires Update on both sides to PATCH a purchase order" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        purchase_order = Model::Generator.asset_purchase_order.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Update).save!

        result = client.patch(
          path: "#{AssetPurchaseOrders.base_route}#{purchase_order.id}",
          body: {purchase_order_number: "po-#{random_name}"}.to_json,
          headers: headers,
        )
        result.success?.should be_true
        purchase_order.destroy
      end

      it "rejects PATCH when the support user only has Create on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        purchase_order = Model::Generator.asset_purchase_order.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Create).save!

        result = client.patch(
          path: "#{AssetPurchaseOrders.base_route}#{purchase_order.id}",
          body: {purchase_order_number: "po-#{random_name}"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
        purchase_order.destroy
      end

      it "requires Delete on both sides to DELETE a purchase order" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        purchase_order = Model::Generator.asset_purchase_order.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Delete).save!

        result = client.delete(path: "#{AssetPurchaseOrders.base_route}#{purchase_order.id}", headers: headers)
        result.success?.should be_true
        Model::AssetPurchaseOrder.find?(purchase_order.id).should be_nil
      end

      it "rejects DELETE when the support user only has Update on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        purchase_order = Model::Generator.asset_purchase_order.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Update).save!

        result = client.delete(path: "#{AssetPurchaseOrders.base_route}#{purchase_order.id}", headers: headers)
        result.status_code.should eq 403
        purchase_order.destroy
      end

      # index/show map the verb bit to None, so the support path requires
      # Manage on the org zone to read.
      it "allows GET index for a support user with Manage on the org zone (both sides)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Manage).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Manage).save!

        result = client.get(AssetPurchaseOrders.base_route, headers: headers)
        result.status_code.should eq 200
      end

      it "rejects GET index when the support user only has Read on the org zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        org_zone = Spec::Authentication.org_zone

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: org_zone, permissions: Model::Permissions::Read).save!

        result = client.get(AssetPurchaseOrders.base_route, headers: headers)
        result.status_code.should eq 403
      end

      it "allows a support-JWT user to POST regardless of group grants" do
        body = Model::Generator.asset_purchase_order.to_json
        result = client.post(
          AssetPurchaseOrders.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 201
        Model::AssetPurchaseOrder.from_trusted_json(result.body).destroy
      end

      it "allows an admin-JWT user to POST regardless of group grants" do
        body = Model::Generator.asset_purchase_order.to_json
        result = client.post(
          AssetPurchaseOrders.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: true, support: false),
        )
        result.status_code.should eq 201
        Model::AssetPurchaseOrder.from_trusted_json(result.body).destroy
      end
    end
  end
end
