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
  end
end
