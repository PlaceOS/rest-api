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

        counts = PlaceOS::Api::AssetTypes.apply_counts([asset_type], "zone-22222222")
        asset_type.@asset_count.should eq 0
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetType, AssetTypes)
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetTypes)
    end
  end
end
