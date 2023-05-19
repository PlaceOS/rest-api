require "../helper"

module PlaceOS::Api
  describe AssetCategories do
    Spec.test_404(AssetCategories.base_route, model_name: Model::AssetCategory.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AssetCategory, AssetCategories)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetCategory, AssetCategories, id_type: Int64)
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetCategories, id_type: Int64)
    end
  end
end
