require "../helper"
require "placeos-core/placeos-edge/client"

module PlaceOS::Api
  describe Edges do
    authenticated_user, authorization_header = authentication
    base = Edges::NAMESPACE[0]

    with_server do
      Specs.test_404(base, model_name: Model::Edge.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        Specs.test_base_index(Model::Edge, Edges)
      end

      describe "control" do
        it "authenticates with an API key from a new edge" do
          # First create a new edge to test with as the countroller would
          edge_name = "Test Edge"

          edge_host = "localhost"
          edge_port = 6000

          create_body = Model::Edge::CreateBody.new(name: edge_name, user_id: authenticated_user.id.as(String))
          new_edge = Model::Edge.for_user(
            user: authenticated_user,
            name: create_body.name,
            description: create_body.description
          )

          # Ensure instance variable initialised and edge saved
          new_edge.x_api_key
          new_edge.save!

          uri = URI.new(host: edge_host, port: edge_port, query: "api-key=#{new_edge.x_api_key}")
          client = PlaceOS::Edge::Client.new(
            uri: uri,
            secret: new_edge.x_api_key
          )

          client.connect do
            client.transport.closed?.should_not be_nil
            client.disconnect
          end
        end
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

            JSON.parse(result.body)["x_api_key"]?.try(&.as_s?).should_not be_nil
          end
        end
      end

      describe "scopes" do
        Specs.test_controller_scope(Edges)
      end
    end
  end
end
