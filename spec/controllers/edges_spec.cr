require "../helper"
require "placeos-core/placeos-edge/client"

module PlaceOS::Api
  describe Edges do
    Spec.test_404(Edges.base_route, model_name: Model::Edge.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::Edge, Edges)
    end

    describe "/control" do
      it "authenticates with an API key from a new edge" do
        # Create a new edge to test with as the controller would
        edge_host = "localhost"

        new_edge = Model::Edge.for_user(
          user: Spec::Authentication.user,
          name: random_name,
        )

        # Ensure instance variable initialised and edge saved
        new_edge.x_api_key
        new_edge.save!

        path = "#{Edges.base_route}/control"

        uri = URI.new(host: edge_host, path: path, query: URI::Params{"api-key" => new_edge.x_api_key})

        edge_client = PlaceOS::Edge::Client.new(
          uri: uri,
          secret: new_edge.x_api_key
        )

        websocket = client.establish_ws(path, headers: HTTP::Headers{"Host" => edge_host})
        edge_client.connect(websocket) do
          edge_client.transport.closed?.should be_false
          edge_client.disconnect
        end
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::Edge, Edges)

      describe "create" do
        it "contains the api token in the response" do
          result = client.post(
            path: Edges.base_route,
            body: {
              "description" => "",
              "name"        => "test-edge",
            }.to_json,
            headers: Spec::Authentication.headers,
          )

          JSON.parse(result.body)["x_api_key"]?.try(&.as_s?).should_not be_nil
        end
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Edges)
    end
  end
end
