require "../helper"

# asserts a successful assets index response and extracts the returned ids
def asset_index_ids(result) : Array(String)
  result.status_code.should eq 200
  Array(Hash(String, JSON::Any))
    .from_json(result.body)
    .map(&.["id"].to_s)
end

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
        doc.persisted?.should be_true

        base = Assets.base_route.rstrip('/')

        # search for the asset directly
        params = HTTP::Params.encode({"q" => identifier, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(doc.id)

        # filter for the asset using its asset type
        type_id = doc.asset_type_id.to_s
        params = HTTP::Params.encode({"type_id" => type_id, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(doc.id)

        # q keeps working combined with a filter
        params = HTTP::Params.encode({"q" => identifier, "type_id" => type_id, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(doc.id)

        # an asset type id that can't exist matches nothing
        params = HTTP::Params.encode({"type_id" => "invalid_id"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should be_empty

        # search for something else
        params = HTTP::Params.encode({"q" => "xxxxxxxxxx"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should_not contain(doc.id)
      end

      it "searches for assets using the asset type name", tags: "search" do
        _, headers = Spec::Authentication.authentication

        asset_type = PlaceOS::Model::Generator.asset_type
        type_name = random_name
        asset_type.name = type_name
        asset_type.save!

        doc = PlaceOS::Model::Generator.asset(asset_type: asset_type).save!
        other = PlaceOS::Model::Generator.asset.save!

        params = HTTP::Params.encode({"q" => type_name, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{Assets.base_route.rstrip('/')}?#{params}", headers: headers))
        ids.should contain(doc.id)
        ids.should_not contain(other.id)

        doc.destroy
        other.destroy
      end

      it "filters assets by zone_id and zones (asset must be in every listed zone)", tags: "search" do
        _, headers = Spec::Authentication.authentication

        zone_a = PlaceOS::Model::Generator.zone.save!
        zone_b = PlaceOS::Model::Generator.zone.save!
        zone_a_id = zone_a.id.as(String)
        zone_b_id = zone_b.id.as(String)

        asset_ab = PlaceOS::Model::Generator.asset
        asset_ab.zone_id = zone_a_id
        asset_ab.zones = [zone_a_id, zone_b_id]
        asset_ab.save!

        asset_b = PlaceOS::Model::Generator.asset
        asset_b.zone_id = zone_b_id
        asset_b.zones = [zone_b_id]
        asset_b.save!

        base = Assets.base_route.rstrip('/')

        # zone_id is an exact match on the asset's primary zone
        params = HTTP::Params.encode({"zone_id" => zone_a_id, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(asset_ab.id)
        ids.should_not contain(asset_b.id)

        # zones requires membership of every listed zone (AND semantics)
        params = HTTP::Params.encode({"zones" => "#{zone_a_id},#{zone_b_id}", "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(asset_ab.id)
        ids.should_not contain(asset_b.id)

        # a single zone matches every asset within it
        params = HTTP::Params.encode({"zones" => zone_b_id, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(asset_ab.id)
        ids.should contain(asset_b.id)

        asset_ab.destroy
        asset_b.destroy
        zone_a.destroy
        zone_b.destroy
      end

      it "filters assets by barcode and serial number", tags: "search" do
        _, headers = Spec::Authentication.authentication

        doc = PlaceOS::Model::Generator.asset
        doc.barcode = "barcode-#{random_name}"
        doc.serial_number = "serial-#{random_name}"
        doc.save!
        other = PlaceOS::Model::Generator.asset.save!

        base = Assets.base_route.rstrip('/')

        params = HTTP::Params.encode({"barcode" => doc.barcode.as(String), "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(doc.id)
        ids.should_not contain(other.id)

        params = HTTP::Params.encode({"serial_number" => doc.serial_number.as(String), "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(doc.id)
        ids.should_not contain(other.id)

        doc.destroy
        other.destroy
      end

      it "filters assets by purchase order id", tags: "search" do
        _, headers = Spec::Authentication.authentication

        purchase_order = PlaceOS::Model::Generator.asset_purchase_order.save!
        doc = PlaceOS::Model::Generator.asset(purchase_order: purchase_order).save!
        other = PlaceOS::Model::Generator.asset.save!

        base = Assets.base_route.rstrip('/')

        params = HTTP::Params.encode({"order_id" => purchase_order.id.to_s, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(doc.id)
        ids.should_not contain(other.id)

        # a purchase order id that can't exist matches nothing
        params = HTTP::Params.encode({"order_id" => "invalid_id"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should be_empty

        doc.destroy
        other.destroy
      end

      it "filters assets by bookable and accessible, including false values", tags: "search" do
        _, headers = Spec::Authentication.authentication

        # generator defaults: bookable = true, accessible = false
        default_asset = PlaceOS::Model::Generator.asset.save!

        flipped_asset = PlaceOS::Model::Generator.asset
        flipped_asset.bookable = false
        flipped_asset.accessible = true
        flipped_asset.save!

        base = Assets.base_route.rstrip('/')

        params = HTTP::Params.encode({"bookable" => "false", "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(flipped_asset.id)
        ids.should_not contain(default_asset.id)

        params = HTTP::Params.encode({"accessible" => "false", "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(default_asset.id)
        ids.should_not contain(flipped_asset.id)

        params = HTTP::Params.encode({"accessible" => "true", "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(flipped_asset.id)
        ids.should_not contain(default_asset.id)

        default_asset.destroy
        flipped_asset.destroy
      end

      it "filters assets by features, matching any listed feature", tags: "search" do
        _, headers = Spec::Authentication.authentication

        feature_a = "feature-#{random_name}"
        feature_b = "feature-#{random_name}"

        asset_a = PlaceOS::Model::Generator.asset
        asset_a.features = [feature_a]
        asset_a.save!

        asset_b = PlaceOS::Model::Generator.asset
        asset_b.features = [feature_b]
        asset_b.save!

        base = Assets.base_route.rstrip('/')

        # multiple features are ORed (Elasticsearch should + minimum_should_match(1))
        params = HTTP::Params.encode({"features" => "#{feature_a},#{feature_b}", "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(asset_a.id)
        ids.should contain(asset_b.id)

        params = HTTP::Params.encode({"features" => feature_a, "limit" => "1000"})
        ids = asset_index_ids(client.get("#{base}?#{params}", headers: headers))
        ids.should contain(asset_a.id)
        ids.should_not contain(asset_b.id)

        asset_a.destroy
        asset_b.destroy
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
