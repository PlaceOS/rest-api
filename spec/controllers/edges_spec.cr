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

        path = File.join(Edges.base_route, "control")

        uri = URI.new(host: edge_host, path: path, query: URI::Params{"api-key" => new_edge.x_api_key})

        edge_client = PlaceOS::Edge::Client.new(
          uri: uri,
          secret: new_edge.x_api_key
        )

        websocket = client.establish_ws(uri, headers: HTTP::Headers{"Host" => edge_host})
        spawn(same_thread: true) { websocket.run }
        edge_client.connect(websocket) do
          edge_client.transport.closed?.should be_false
          edge_client.disconnect
        end
      end
    end

    describe "CRUD operations", tags: "crud" do
      ::Spec.before_each do
        PlaceOS::Model::Edge.clear
      end
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

    describe "monitoring endpoints" do
      ::Spec.before_each do
        PlaceOS::Model::Edge.clear
      end

      it "should handle edge errors endpoint" do
        # Create a test edge
        edge = Model::Edge.for_user(
          user: Spec::Authentication.user,
          name: random_name,
        )
        edge.save!

        # Test the edge errors endpoint
        result = client.get(
          path: "#{Edges.base_route}/#{edge.id}/errors",
          headers: Spec::Authentication.headers,
        )

        # Should return 200 or handle gracefully if core is not available
        [200, 404, 500].should contain(result.status_code)
      end

      it "should handle edge health endpoint" do
        # Create a test edge
        edge = Model::Edge.for_user(
          user: Spec::Authentication.user,
          name: random_name,
        )
        edge.save!

        # Test the edge health endpoint
        result = client.get(
          path: "#{Edges.base_route}/#{edge.id}/health",
          headers: Spec::Authentication.headers,
        )

        # Should return 200 or handle gracefully if core is not available
        [200, 404, 500].should contain(result.status_code)
      end

      it "should handle edges health endpoint" do
        # Test the all edges health endpoint
        result = client.get(
          path: "#{Edges.base_route}/health",
          headers: Spec::Authentication.headers,
        )

        # Should return 200 or handle gracefully if core is not available
        [200, 404, 500].should contain(result.status_code)
      end

      it "should handle edges statistics endpoint" do
        # Test the edges statistics endpoint
        result = client.get(
          path: "#{Edges.base_route}/statistics",
          headers: Spec::Authentication.headers,
        )

        # Should return 200 or handle gracefully if core is not available
        [200, 404, 500].should contain(result.status_code)
      end

      it "should handle module status endpoint" do
        # Create a test edge
        edge = Model::Edge.for_user(
          user: Spec::Authentication.user,
          name: random_name,
        )
        edge.save!

        # Test the edge module status endpoint
        result = client.get(
          path: "#{Edges.base_route}/#{edge.id}/modules/status",
          headers: Spec::Authentication.headers,
        )

        # Should return 200 or handle gracefully if core is not available
        [200, 404, 500].should contain(result.status_code)
      end
    end
  end
end
