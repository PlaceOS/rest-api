require "../helper"
require "placeos-core/placeos-edge/client"

module PlaceOS::Api
  TEST_EDGE_JSON = "{\"name\":\"Test Edge\",\"description\":\"A test edge\"}"
  TEST_LOCAL_HOST = "localhost"
  TEST_LOCAL_PORT = 6000
  describe Edges do
    _authenticated_user, authorization_header = authentication
    base = Edges::NAMESPACE[0]

    with_server do
      Specs.test_404(base, model_name: Model::Edge.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        Specs.test_base_index(Model::Edge, Edges)
      end

      describe "control" do
        it "authenticates with an API key from a new edge" do
          # First create a new edge to test with as the countroller would
          create_body = Model::Edge::CreateBody.from_json(TEST_EDGE_JSON)
          new_edge = Model::Edge.for_user(
            user: _authenticated_user,
            name: create_body.name,
            description: create_body.description
          )

          # Ensure instance variable initialised and edge saved
          new_edge.x_api_key
          new_edge.save!
          
          uri = URI.new(host: TEST_LOCAL_HOST)
          uri.port = TEST_LOCAL_PORT
          uri.query = "api-key=#{new_edge.x_api_key}"
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
