require "../helper"

module PlaceOS::Api
  describe AssetTypes do
    Spec.test_404(AssetTypes.base_route, model_name: Model::AssetType.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AssetType, AssetTypes)

      it "optimally solves the N+1 problem" do
        asset = PlaceOS::Model::Generator.asset.save!

        asset.should_not be_nil
        asset.persisted?.should be_true

        asset_type = asset.asset_type.as(PlaceOS::Model::AssetType)

        counts = PlaceOS::Api::AssetTypes.apply_counts([asset_type])
        counts[asset_type.id].should eq 1
        asset_type.@asset_count.should eq 1

        PlaceOS::Api::AssetTypes.apply_counts([asset_type], "zone-22222222")
        asset_type.@asset_count.should eq 0
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetType, AssetTypes)
      Spec.test_crd(Model::AssetType, AssetTypes, sys_admin: false, support: false, groups: ["management"])
      Spec.test_crd(Model::AssetType, AssetTypes, sys_admin: false, support: false, groups: ["concierge"])

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.asset_type.to_json
        result = client.post(
          Assets.base_route,
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
