require "../helper"

module PlaceOS::Api
  describe AssetTypes do
    Spec.test_404(AssetTypes.base_route, model_name: Model::AssetType.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      it "should return an empty array when no matching asset types found" do
        PlaceOS::Model::Asset.clear
        PlaceOS::Model::AssetType.clear
        params = HTTP::Params.encode({"zone_id" => "unknown-zone"})
        path = "#{AssetTypes.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq(200)
        body = JSON.parse(result.body)
        body.as_a?.should_not be_nil
        body.as_a.size.should be >= 0
      end

      it "should return json when get request is invoked for matching asset-types" do
        PlaceOS::Model::Asset.clear
        PlaceOS::Model::AssetType.clear
        asset = PlaceOS::Model::Generator.asset.save!
        params = HTTP::Params.encode({"zone_id" => asset.zone_id.to_s})
        path = "#{AssetTypes.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq(200)
        body = JSON.parse(result.body)
        body.as_a?.should_not be_nil
        body.as_a.size.should be >= 1
        body.as_a.first["asset_count"].should eq(1)

        params = HTTP::Params.encode({"zone_id" => "zone-000000"})
        path = "#{AssetTypes.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq(200)
        body = JSON.parse(result.body)
        body.as_a?.should_not be_nil
        body.as_a.size.should be >= 1
        body.as_a.first["asset_count"].should eq(0)
      end

      it "should filter by category_id" do
        PlaceOS::Model::Asset.clear
        PlaceOS::Model::AssetType.clear

        # this will generate 2 categories so we can ensure only 1 is returned
        asset1 = PlaceOS::Model::Generator.asset_type.save!
        asset2 = PlaceOS::Model::Generator.asset_type.save!
        category_id = asset2.category_id

        params = HTTP::Params.encode({"category_id" => category_id.to_s})
        path = "#{AssetTypes.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq(200)

        body = JSON.parse(result.body)
        body.as_a?.should_not be_nil
        body.as_a.size.should eq(1)
        body.as_a.first["id"].as_s.should eq(asset2.id)

        # check we can return both
        asset1.category_id = category_id
        asset1.save!
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq(200)
        body = JSON.parse(result.body)
        body.as_a?.should_not be_nil
        body.as_a.size.should eq(2)
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetType, AssetTypes)
      Spec.test_crd(Model::AssetType, AssetTypes, sys_admin: false, support: false, groups: ["management"])
      Spec.test_crd(Model::AssetType, AssetTypes, sys_admin: false, support: false, groups: ["concierge"])

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.asset_type.to_json
        result = client.post(
          AssetTypes.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetTypes)
    end
  end
end
