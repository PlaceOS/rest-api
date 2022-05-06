require "../helper"

module PlaceOS::Api
  describe Edges do
    _authenticated_user, authorization_header = authentication
    base = Edges::NAMESPACE[0]

    with_server do
      Specs.test_404(base, model_name: Model::Edge.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        Specs.test_base_index(Model::Edge, Edges)
      end

      describe "CRUD operations", tags: "crud" do
        Specs.test_crd(Model::Edge, Edges)

        describe "create" do
          it "contains the api token in the response" do
            result = curl(
              method: "POST",
              path: base,
              body: {
                "description" => "",
                "name"        => "test-edge",
              }.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )
            result.body.should contain "x_api_key"
          end
        end
      end

      describe "scopes" do
        Specs.test_controller_scope(Edges)
      end
    end
  end
end
