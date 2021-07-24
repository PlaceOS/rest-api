require "./helper"

module PlaceOS::Api
  describe ApiKeys do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = ApiKeys::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::ApiKey.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        test_base_index(Model::ApiKey, ApiKeys)
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(Model::ApiKey, ApiKeys)
      end
    end
  end
end
