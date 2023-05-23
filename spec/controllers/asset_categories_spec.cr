require "../helper"

module PlaceOS::Api
  describe AssetCategories do
    Spec.test_404(AssetCategories.base_route, model_name: Model::AssetCategory.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AssetCategory, AssetCategories)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetCategory, AssetCategories, id_type: Int64)

      it "only needs a name to create" do
        request_body = {name: "test category"}
        result = client.post(
          AssetCategories.base_route,
          body: request_body.to_json,
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq(201)
        response_model = Model::AssetCategory.from_trusted_json(result.body)
        response_model.name.should eq(request_body[:name])
        response_model.destroy
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetCategories, id_type: Int64)
    end
  end
end
