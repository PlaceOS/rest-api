require "../helper"

module PlaceOS::Api
  describe Assets do
    Spec.test_404(Assets.base_route, model_name: Model::Asset.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      it "queries Asset", tags: "search" do
        _, headers = Spec::Authentication.authentication
        doc = PlaceOS::Model::Generator.asset
        identifier = random_name
        doc.identifier = identifier
        doc.save!

        refresh_elastic(Model::Asset.table_name)
        doc.persisted?.should be_true

        # search for the asset directly
        params = HTTP::Params.encode({"q" => identifier})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        found = until_expected("GET", path, headers) do |response|
          Array(Hash(String, JSON::Any))
            .from_json(response.body)
            .map(&.["id"].to_s)
            .any?(doc.id)
        end
        found.should be_true

        # don't use until expected once the doc is indexed
        client = ActionController::SpecHelper.client

        # search for asset using asset type
        type_id = doc.asset_type_id.to_s
        params = HTTP::Params.encode({"type_id" => type_id})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        response = client.exec(method: "GET", path: path, headers: headers)
        found = Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map(&.["id"].to_s)
          .any?(doc.id)
        found.should be_true

        # search for asset using asset type
        params = HTTP::Params.encode({"type_id" => "invalid_id"})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        response = client.exec(method: "GET", path: path, headers: headers)
        found = Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map(&.["id"].to_s)
          .any?(doc.id)
        found.should be_false

        # search for something else
        params = HTTP::Params.encode({"q" => "xxxxxxxxxx"})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        response = client.exec(method: "GET", path: path, headers: headers)
        found = Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map(&.["id"].to_s)
          .any?(doc.id)
        found.should be_false

        # TODO:: search for asset using the asset type name
        # type_name = doc.asset_type.not_nil!.name
        # params = HTTP::Params.encode({"q" => type_name})
        # path = "#{Assets.base_route.rstrip('/')}?#{params}"
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::Asset, Assets)
      Spec.test_crd(Model::Asset, Assets, sys_admin: false, support: false, groups: ["management"])
      Spec.test_crd(Model::Asset, Assets, sys_admin: false, support: false, groups: ["concierge"])

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.asset.to_json
        result = client.post(
          Assets.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Assets)
    end

    describe "support-subsystem permissions" do
      ::Spec.before_each { clear_group_tables }

      # Build an Asset (unsaved) whose `zone_id` is the supplied zone.
      build_asset = ->(zone : Model::Zone) {
        asset_type = Model::Generator.asset_type.save!
        purchase_order = Model::Generator.asset_purchase_order.save!
        asset = Model::Asset.new(
          asset_type_id: asset_type.id,
          purchase_order_id: purchase_order.id,
          zone_id: zone.id,
        )
        asset
      }

      it "allows POST for a support user with Create on both sides of the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Create).save!

        asset = build_asset.call(zone)
        result = client.post(Assets.base_route, body: asset.to_json, headers: headers)
        result.status_code.should eq 201

        created = Model::Asset.from_trusted_json(result.body)
        created.destroy
        zone.destroy
      end

      it "rejects POST when the support user only has Read on the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        asset = build_asset.call(zone)
        result = client.post(Assets.base_route, body: asset.to_json, headers: headers)
        result.status_code.should eq 403
        zone.destroy
      end

      it "requires Update on both sides to PATCH an asset" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        asset = build_asset.call(zone).save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Update).save!

        result = client.patch(
          path: "#{Assets.base_route}#{asset.id}",
          body: {name: "renamed-#{random_name}"}.to_json,
          headers: headers,
        )
        result.success?.should be_true

        asset.destroy
        zone.destroy
      end

      it "rejects PATCH when the support user only has Create on the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        asset = build_asset.call(zone).save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Create).save!

        result = client.patch(
          path: "#{Assets.base_route}#{asset.id}",
          body: {name: "renamed-#{random_name}"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403

        asset.destroy
        zone.destroy
      end

      it "requires Delete on both sides to DELETE an asset" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        asset = build_asset.call(zone).save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Delete).save!

        result = client.delete(path: "#{Assets.base_route}#{asset.id}", headers: headers)
        result.success?.should be_true
        Model::Asset.find?(asset.id).should be_nil

        zone.destroy
      end

      it "rejects DELETE when the support user only has Update on the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        asset = build_asset.call(zone).save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Update).save!

        result = client.delete(path: "#{Assets.base_route}#{asset.id}", headers: headers)
        result.status_code.should eq 403

        asset.destroy
        zone.destroy
      end

      it "rejects POST when the support grant is on a different zone than the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        asset_zone = Model::Generator.zone.save!
        other_zone = Model::Generator.zone.save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        # grant is on `other_zone`, but the asset lives in `asset_zone`
        Model::Generator.group_zone(group: group, zone: other_zone, permissions: Model::Permissions::Create).save!

        asset = build_asset.call(asset_zone)
        result = client.post(Assets.base_route, body: asset.to_json, headers: headers)
        result.status_code.should eq 403

        asset_zone.destroy
        other_zone.destroy
      end

      it "gates POST /assets/bulk: rejects when user lacks a grant on the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        asset_zone = Model::Generator.zone.save!
        other_zone = Model::Generator.zone.save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: other_zone, permissions: Model::Permissions::Create).save!

        asset = build_asset.call(asset_zone)
        result = client.post(
          "#{Assets.base_route}bulk",
          body: [asset].to_json,
          headers: headers,
        )
        result.status_code.should eq 403

        asset_zone.destroy
        other_zone.destroy
      end

      it "gates POST /assets/bulk: succeeds with a proper Create grant on the asset's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Create).save!

        asset = build_asset.call(zone)
        result = client.post(
          "#{Assets.base_route}bulk",
          body: [asset].to_json,
          headers: headers,
        )
        result.status_code.should eq 201

        Array(Model::Asset).from_json(result.body).each(&.destroy)
        zone.destroy
      end

      it "allows a support-JWT user to POST regardless of group grants" do
        zone = Model::Generator.zone.save!
        asset = build_asset.call(zone)
        result = client.post(
          Assets.base_route,
          body: asset.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 201

        created = Model::Asset.from_trusted_json(result.body)
        created.destroy
        zone.destroy
      end

      it "allows an admin-JWT user to POST regardless of group grants" do
        zone = Model::Generator.zone.save!
        asset = build_asset.call(zone)
        result = client.post(
          Assets.base_route,
          body: asset.to_json,
          headers: Spec::Authentication.headers(sys_admin: true, support: false),
        )
        result.status_code.should eq 201

        created = Model::Asset.from_trusted_json(result.body)
        created.destroy
        zone.destroy
      end
    end
  end
end
