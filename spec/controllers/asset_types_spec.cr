require "../helper"

module PlaceOS::Api
  describe AssetTypes do
    Spec.test_404(AssetTypes.base_route, model_name: Model::AssetType.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AssetType, AssetTypes)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetType, AssetTypes)
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetTypes)
    end
  end
end
