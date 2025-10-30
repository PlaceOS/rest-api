require "promise"
require "uuid"
require "placeos-core-client"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edges < Application
    base "/api/engine/v2/edges/"

    # Scopes
    ###############################################################################################

    generate_scope_check(::PlaceOS::Model::Edge::CONTROL_SCOPE)

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_admin, except: [:index, :show, :edge_control]
    before_action :check_support, only: [:index, :show]

    before_action :can_write_edge_control, only: [:edge_control]

    # Callbacks
    ###############################################################################################

    skip_action :set_user_id, only: [:edge_control]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :edge_control])]
    def find_current_edge(id : String)
      Log.context.set(edge_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_edge = ::PlaceOS::Model::Edge.find!(id)
    end

    getter! current_edge : ::PlaceOS::Model::Edge

    ###############################################################################################

    class_getter connection_manager : ConnectionManager { ConnectionManager.new(RemoteDriver.default_discovery) }

    # Validate the present of the id and check the secret before routing to core

    # the websocket endpoint that edge devices use to connect to the cluster
    @[AC::Route::WebSocket("/control")]
    def edge_control(socket) : Nil
      edge_id = ::PlaceOS::Model::Edge.jwt_edge_id?(user_token)

      if edge_id.nil? || !Model::Edge.exists?(edge_id)
        raise Error::Forbidden.new("not an edge lord")
      else
        Log.info { {edge_id: edge_id, message: "new edge connection"} }
        Edges.connection_manager.add_edge(edge_id, socket)
      end
    end

    # admins can obtain the token edge nodes will use to connect to the cluster
    @[AC::Route::GET("/:id/token")]
    def token : NamedTuple(token: String)
      raise Error::Forbidden.new("not an admin") unless user_admin?
      {token: current_edge.x_api_key}
    end

    # list the edges in the system.
    # an edge can be thought of as a location and each edge location can have multiple nodes servicing it
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::Edge)
      elastic = ::PlaceOS::Model::Edge.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # return the details of an edge location
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Edge
      current_edge
    end

    # update the details of an edge location
    @[AC::Route::PATCH("/:id", body: :edge)]
    @[AC::Route::PUT("/:id", body: :edge)]
    def update(edge : ::PlaceOS::Model::Edge) : ::PlaceOS::Model::Edge
      current = current_edge
      current.assign_attributes(edge)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new edge location
    @[AC::Route::POST("/", body: :create_body, status_code: HTTP::Status::CREATED)]
    def create(create_body : ::PlaceOS::Model::Edge::CreateBody) : ::PlaceOS::Model::Edge::KeyResponse
      user = ::PlaceOS::Model::User.find!(create_body.user_id || current_user.id.as(String))
      new_edge = ::PlaceOS::Model::Edge.for_user(
        user: user,
        name: create_body.name,
        description: create_body.description
      )

      # Ensure instance variable initialised
      new_edge.x_api_key

      raise Error::ModelValidation.new(new_edge.errors) unless new_edge.save
      new_edge.to_key_struct
    end

    # remove an edge location
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_edge.destroy
    end

    # Edge Monitoring Endpoints
    ###############################################################################################

    # Get errors for a specific edge
    @[AC::Route::GET("/:id/errors")]
    def edge_errors(
      @[AC::Param::Info(description: "Number of recent errors to return")]
      limit : Int32 = 50,
      @[AC::Param::Info(description: "Error type filter")]
      type : String? = nil,
    ) : Array(PlaceOS::Core::Client::EdgeError)
      edge_id = current_edge.id.as(String)

      # Find a core node that manages this edge
      core_uri = find_core_for_edge(edge_id)

      # Use core client method directly
      core_for_uri(core_uri, request_id) do |core_client|
        core_client.edge_errors(edge_id, limit, type)
      end
    end

    # Get module status for a specific edge
    @[AC::Route::GET("/:id/modules/status")]
    def edge_module_status : PlaceOS::Core::Client::EdgeModuleStatus
      edge_id = current_edge.id.as(String)

      # Find a core node that manages this edge
      core_uri = find_core_for_edge(edge_id)

      # Use core client method directly
      core_for_uri(core_uri, request_id) do |core_client|
        core_client.edge_module_status(edge_id)
      end
    end

    # Get health status for a specific edge
    @[AC::Route::GET("/:id/health")]
    def edge_health : PlaceOS::Core::Client::EdgeHealth?
      edge_id = current_edge.id.as(String)

      # Find a core node that manages this edge
      core_uri = find_core_for_edge(edge_id)

      # Use core client method directly
      core_for_uri(core_uri, request_id) do |core_client|
        health_data = core_client.edges_health
        # Extract health for this specific edge
        health_data[edge_id]?
      end
    end

    # Get connection metrics for a specific edge
    @[AC::Route::GET("/:id/connections")]
    def edge_connections : PlaceOS::Core::Client::ConnectionMetrics?
      edge_id = current_edge.id.as(String)

      # Find a core node that manages this edge
      core_uri = find_core_for_edge(edge_id)

      # Use core client method directly
      core_for_uri(core_uri, request_id) do |core_client|
        connections_data = core_client.edges_connections
        # Extract connections for this specific edge
        connections_data[edge_id]?
      end
    end

    # Get health status for all edges
    @[AC::Route::GET("/health")]
    def edges_health : Hash(String, PlaceOS::Core::Client::EdgeHealth)
      # Collect health data from all core nodes
      collect_edges_health
    end

    # Get errors from all edges
    @[AC::Route::GET("/errors")]
    def edges_errors(
      @[AC::Param::Info(description: "Number of recent errors to return")]
      limit : Int32 = 50,
      @[AC::Param::Info(description: "Error type filter")]
      type : String? = nil,
    ) : Hash(String, Array(PlaceOS::Core::Client::EdgeError))
      collect_edges_errors(limit, type)
    end

    # Get connection metrics for all edges
    @[AC::Route::GET("/connections")]
    def edges_connections : Hash(String, PlaceOS::Core::Client::ConnectionMetrics)
      collect_edges_connections
    end

    # Get module failures from all edges
    @[AC::Route::GET("/modules/failures")]
    def edges_module_failures : Hash(String, Array(Hash(String, JSON::Any)))
      collect_edges_module_failures
    end

    # Get overall edge statistics
    @[AC::Route::GET("/statistics")]
    def edges_statistics : PlaceOS::Core::Client::EdgeStatistics
      collect_edges_statistics
    end

    # Real-time error streaming for a specific edge
    @[AC::Route::WebSocket("/:id/errors/stream")]
    def edge_error_stream(socket, id : String) : Nil
      edge_id = id

      # Validate edge exists
      _ = ::PlaceOS::Model::Edge.find!(edge_id)

      # Find a core node that manages this edge
      core_uri = find_core_for_edge(edge_id)

      # Set up the monitoring stream connection
      setup_monitoring_stream(socket, core_uri, "/api/core/v1/monitoring/edge/#{edge_id}/errors/stream")
    end

    # Real-time error streaming for all edges
    @[AC::Route::WebSocket("/errors/stream")]
    def edges_error_stream(socket) : Nil
      # This would need to aggregate streams from multiple core nodes
      # For now, connect to the first available core node
      core_nodes = RemoteDriver.default_discovery.node_hash

      if core_nodes.empty?
        socket.close(1000, "No core nodes available")
        return
      end

      core_uri = core_nodes.first_value

      # Set up the monitoring stream connection
      setup_monitoring_stream(socket, core_uri, "/api/core/v1/monitoring/edges/errors/stream")
    end

    # Real-time module status streaming for all edges
    @[AC::Route::WebSocket("/modules/stream")]
    def edges_module_stream(socket) : Nil
      # Similar to error streaming but for module status
      core_nodes = RemoteDriver.default_discovery.node_hash

      if core_nodes.empty?
        socket.close(1000, "No core nodes available")
        return
      end

      core_uri = core_nodes.first_value

      # Set up the monitoring stream connection
      setup_monitoring_stream(socket, core_uri, "/api/core/v1/monitoring/edges/modules/stream")
    end

    # Manual error cleanup trigger
    @[AC::Route::POST("/monitoring/cleanup")]
    def cleanup_errors(
      @[AC::Param::Info(description: "Hours of error history to retain")]
      hours : Int32 = 24,
    ) : Hash(String, Hash(String, JSON::Any))
      # Trigger cleanup on all core nodes
      core_nodes = RemoteDriver.default_discovery.node_hash
      results = {} of String => Hash(String, JSON::Any)

      core_nodes.each do |core_id, uri|
        begin
          core_for_uri(uri, request_id) do |core_client|
            cleanup_result = core_client.cleanup_edge_errors(hours)
            results[core_id] = cleanup_result
          end
        rescue e
          results[core_id] = {"error" => JSON::Any.new(e.message)}
        end
      end

      results
    end

    # Real-time error summary
    @[AC::Route::GET("/monitoring/summary")]
    def monitoring_summary : Hash(String, Hash(String, JSON::Any))
      collect_monitoring_summary
    end

    # Helper Methods
    ###############################################################################################

    private def find_core_for_edge(edge_id : String) : URI
      # For now, use the first available core node
      # In a more sophisticated setup, you might track which core manages which edge
      core_nodes = RemoteDriver.default_discovery.node_hash

      if core_nodes.empty?
        raise Error::NotFound.new("No core nodes available")
      end

      # Return the first available core node URI
      core_nodes.first_value
    end

    private def collect_edges_health : Hash(String, PlaceOS::Core::Client::EdgeHealth)
      core_nodes = RemoteDriver.default_discovery.node_hash
      results = {} of String => PlaceOS::Core::Client::EdgeHealth

      core_nodes.each do |core_id, uri|
        begin
          core_for_uri(uri, request_id) do |core_client|
            health_data = core_client.edges_health
            results.merge!(health_data)
          end
        rescue e
          Log.warn { "Failed to collect health data from core #{core_id}: #{e.message}" }
        end
      end

      results
    end

    private def collect_edges_errors(limit : Int32, type : String?) : Hash(String, Array(PlaceOS::Core::Client::EdgeError))
      core_nodes = RemoteDriver.default_discovery.node_hash
      results = {} of String => Array(PlaceOS::Core::Client::EdgeError)

      core_nodes.each do |core_id, uri|
        begin
          core_for_uri(uri, request_id) do |core_client|
            errors_data = core_client.edges_errors(limit, type)
            results.merge!(errors_data)
          end
        rescue e
          Log.warn { "Failed to collect errors from core #{core_id}: #{e.message}" }
        end
      end

      results
    end

    private def collect_edges_connections : Hash(String, PlaceOS::Core::Client::ConnectionMetrics)
      core_nodes = RemoteDriver.default_discovery.node_hash
      results = {} of String => PlaceOS::Core::Client::ConnectionMetrics

      core_nodes.each do |core_id, uri|
        begin
          core_for_uri(uri, request_id) do |core_client|
            connections_data = core_client.edges_connections
            results.merge!(connections_data)
          end
        rescue e
          Log.warn { "Failed to collect connections from core #{core_id}: #{e.message}" }
        end
      end

      results
    end

    private def collect_edges_module_failures : Hash(String, Array(Hash(String, JSON::Any)))
      core_nodes = RemoteDriver.default_discovery.node_hash
      results = {} of String => Array(Hash(String, JSON::Any))

      core_nodes.each do |core_id, uri|
        begin
          core_for_uri(uri, request_id) do |core_client|
            failures_data = core_client.edges_module_failures
            results.merge!(failures_data)
          end
        rescue e
          Log.warn { "Failed to collect module failures from core #{core_id}: #{e.message}" }
        end
      end

      results
    end

    private def collect_edges_statistics : PlaceOS::Core::Client::EdgeStatistics
      # For statistics, we'll aggregate from the first available core node
      # In a more sophisticated setup, you might want to aggregate across all cores
      core_nodes = RemoteDriver.default_discovery.node_hash

      core_nodes.each do |core_id, uri|
        begin
          return core_for_uri(uri, request_id) do |core_client|
            core_client.edges_statistics
          end
        rescue e
          Log.warn { "Failed to collect statistics from core #{core_id}: #{e.message}" }
        end
      end

      # Return empty statistics if no core is available
      raise Error::NotFound.new("No core nodes available for statistics")
    end

    private def collect_monitoring_summary : Hash(String, Hash(String, JSON::Any))
      core_nodes = RemoteDriver.default_discovery.node_hash
      results = {} of String => Hash(String, JSON::Any)

      core_nodes.each do |core_id, uri|
        begin
          core_for_uri(uri, request_id) do |core_client|
            summary_data = core_client.edge_monitoring_summary
            results[core_id] = summary_data
          end
        rescue e
          Log.warn { "Failed to collect monitoring summary from core #{core_id}: #{e.message}" }
          results[core_id] = {"error" => JSON::Any.new(e.message)}
        end
      end

      results
    end

    private def core_for_uri(uri : URI, request_id : String? = nil, & : PlaceOS::Core::Client -> V) forall V
      PlaceOS::Core::Client.client(uri: uri, request_id: request_id) do |client|
        yield client
      end
    end

    # Set up a monitoring WebSocket stream connection to core
    private def setup_monitoring_stream(client_socket : HTTP::WebSocket, core_uri : URI, core_path : String) : Nil
      # Create WebSocket connection to core
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = request_id || UUID.random.to_s

      core_ws = HTTP::WebSocket.new(
        host: core_uri.host.not_nil!,
        port: core_uri.port || 3000,
        path: core_path,
        headers: headers
      )

      # Set up error handling and cleanup
      core_ws.on_close do |code, message|
        Log.debug { "Core monitoring stream closed: #{code} - #{message}" }
        client_socket.close(code, message) unless client_socket.closed?
      end

      client_socket.on_close do |code, message|
        Log.debug { "Client monitoring stream closed: #{code} - #{message}" }
        core_ws.close(code, message) unless core_ws.closed?
      end

      # Forward messages from core to client
      core_ws.on_message do |message|
        begin
          client_socket.send(message) unless client_socket.closed?
        rescue e
          Log.error(exception: e) { "Error forwarding message from core to client" }
          core_ws.close unless core_ws.closed?
        end
      end

      # Handle ping/pong for keepalive (similar to connection manager)
      core_ws.on_ping do |data|
        begin
          client_socket.ping(data) unless client_socket.closed?
        rescue e
          Log.error(exception: e) { "Error forwarding ping from core to client" }
        end
      end

      core_ws.on_pong do |data|
        begin
          client_socket.pong(data) unless client_socket.closed?
        rescue e
          Log.error(exception: e) { "Error forwarding pong from core to client" }
        end
      end

      client_socket.on_ping do |data|
        begin
          core_ws.ping(data) unless core_ws.closed?
        rescue e
          Log.error(exception: e) { "Error forwarding ping from client to core" }
        end
      end

      client_socket.on_pong do |data|
        begin
          core_ws.pong(data) unless core_ws.closed?
        rescue e
          Log.error(exception: e) { "Error forwarding pong from client to core" }
        end
      end

      # Start the core WebSocket connection in a separate fiber
      spawn do
        begin
          core_ws.run
        rescue e
          Log.error(exception: e) { "Core monitoring WebSocket error" }
          client_socket.close unless client_socket.closed?
        end
      end

      # Yield to allow the connection to establish
      Fiber.yield
    end
  end
end

require "./edges/connection_manager"
