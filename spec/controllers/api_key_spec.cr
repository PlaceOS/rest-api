require "../helper"

module PlaceOS::Api
  describe ApiKeys do
    _, scoped_authorization_header = x_api_authentication

    Specs.test_404(ApiKeys.base_route, model_name: Model::ApiKey.table_name, headers: scoped_authorization_header)

    describe "index", tags: "search" do
      Specs.test_base_index(Model::ApiKey, ApiKeys)
    end

    describe "CRUD operations", tags: "crud" do
      Specs.test_crd(Model::ApiKey, ApiKeys)
    end

    describe "scopes" do
      Specs.test_controller_scope(ApiKeys)
    end
  end
end
