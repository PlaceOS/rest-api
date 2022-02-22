require "../helper"

module PlaceOS::Api
  describe Edges, focus: true do
    _authenticated_user, authorization_header = authentication
    base = Edges::NAMESPACE[0]

    with_server do
      Specs.test_404(base, model_name: Model::Edge.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        Specs.test_base_index(Model::Edge, Edges)
      end

      describe "CRUD operations", tags: "crud" do
        it "create" do
          name = random_name

          result = curl(
            method: "POST",
            path: base,
            body: {name: name}.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 201

          response_model = Model::Edge.from_trusted_json(result.body)
          response_model.name.should eq(name)
          response_model.destroy
        end

        Specs.test_show(Model::Edge, Edges)
        Specs.test_destroy(Model::Edge, Edges)
      end

      describe "scopes" do
        Specs.test_controller_scope(Edges)
      end
    end
  end
end
