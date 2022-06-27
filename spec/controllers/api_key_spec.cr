require "../helper"

module PlaceOS::Api
  describe ApiKeys do
    _, scoped_headers = Spec::Authentication.x_api_authentication
    before_all { _, scoped_headers = Spec::Authentication.x_api_authentication }

    Spec.test_404(ApiKeys.base_route, model_name: Model::ApiKey.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::ApiKey, ApiKeys)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::ApiKey, ApiKeys)
    end

    describe "scopes" do
      Spec.test_controller_scope(ApiKeys)
    end
  end
end
