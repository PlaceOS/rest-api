require "placeos-core-client"
require "promise"

require "./application"

module PlaceOS::Api
  class Cluster < Application
    base "/api/engine/v2/cluster/"

    # Scopes
    ###############################################################################################

    before_action :check_admin
    before_action :can_read, only: [:nodes, :show]
    before_action :can_write, only: [:destroy]

    ###############################################################################################

    # returns the list of core nodes running in the cluster
    @[AC::Route::GET("/")]
    def nodes(
      @[AC::Param::Info(description: "return the detailed status of the node including memory and CPU usage?", example: "true")]
      include_status : Bool = false
    ) : Array(NodeStatus)
      details = RemoteDriver.default_discovery.node_hash

      if include_status
        promises = details.map do |core_id, uri|
          Promise.defer {
            Cluster.node_status(core_id, uri, request_id)
          }.catch { |error|
            Log.error(exception: error) { {
              message:  "failure to request a core node's status",
              core_uri: uri.to_s,
              core_id:  core_id,
            } }
            nil
          }
        end

        # [
        #   {
        #     "load": <load>,
        #     "status": <status>,
        #     "uri": <uri>,
        #     "id": <id>
        #   },
        #   ...
        # ]
        Promise.all(promises).get.compact
      else
        # [ { "uri": <uri>, "id": <id> }, ... ]
        details.map do |id, uri|
          NodeStatus.new(
            id: id,
            uri: uri,
            load: nil.as(PlaceOS::Core::Client::Load?),
            status: nil.as(PlaceOS::Core::Client::CoreStatus?),
          )
        end
      end
    end

    record NodeStatus,
      id : String,
      uri : URI,
      # Get the cluster load
      load : PlaceOS::Core::Client::Load?,
      # Get the cluster details (number of drivers running, errors etc)
      status : PlaceOS::Core::Client::CoreStatus? { include JSON::Serializable }

    def self.node_status(core_id : String, uri : URI, request_id : String) : NodeStatus?
      Core::Client.client(uri, request_id) do |client|
        NodeStatus.new(
          id: core_id,
          uri: uri,
          # Get the cluster load
          load: client.core_load,
          # Get the cluster details (number of drivers running, errors etc)
          status: client.core_status,
        )
      end
    rescue e
      Log.warn(exception: e) { {message: "failed to request core status", uri: uri.to_s, core_id: core_id} }
      nil
    end

    # Collect unique driver keys managed by a core node
    #
    def self.collect_keys(loaded : PlaceOS::Core::Client::Loaded)
      loaded.edge
        .flat_map(&.last.keys)        # Extract driver keys from each edge bound to the core
        .concat(loaded.local.keys)    # Extract driver keys from the core
        .map!(&.rpartition('/').last) # Strip any path prefix, retaining only the driver key
        .to_set
    end

    # return the details of a particular core node
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "id", description: "specifies the core node we want to send the request to")]
      core_id : String,
      @[AC::Param::Info(description: "return the detailed status of the drivers running on the node?", example: "true")]
      include_status : Bool = false
    ) : Array(DriverStatus)
      uri = RemoteDriver.default_discovery.node_hash[core_id]?

      Log.context.set(core_id: core_id, uri: uri.try &.to_s, include_status: include_status)

      if uri.nil?
        Log.debug { "core not registered" }
        raise Error::NotFound.new("core not registered: #{core_id}")
      end

      Core::Client.client(uri, request_id) do |client|
        loaded = client.loaded

        # Collect unique driver keys managed by node
        driver_keys = Cluster.collect_keys(loaded)

        Log.debug { {loaded: loaded.to_json} }

        if include_status
          promises = driver_keys.map do |key|
            Promise.defer(timeout: 300.seconds) do
              driver_status = begin
                client.driver_status(key)
              rescue e
                Log.warn(exception: e) { {
                  message:    "failed to request driver status",
                  driver_key: key,
                } }
                nil
              end

              Cluster.driver_status(key, loaded, driver_status) unless driver_status.nil?
            end
          end

          # [
          #   {
          #     "driver": "<driver_key>",
          #     "local": { "modules": [<module_id>], "status": <driver_status> }
          #     "edge": {
          #       <edge_id>: { "modules": [<module_id>], "status": <driver_status> }
          #     }
          #   }
          # ]
          Promise.all(promises).get.compact
        else
          # [
          #   {
          #     "driver": "<driver_key>",
          #     "local": { "modules": [<module_id>] }
          #     "edge": {
          #       <edge_id>: { "modules": [<module_id>] }
          #     }
          #   }
          # ]
          driver_keys.map { |key| Cluster.driver_status(key, loaded) }
        end
      end
    end

    record Driver, modules : Array(String), status : PlaceOS::Core::Client::DriverStatus::Metadata? { include JSON::Serializable }
    record DriverStatus, driver : String, local : Driver, edge : Hash(String, Driver) { include JSON::Serializable }

    def self.driver_status(
      key : String,
      loaded : PlaceOS::Core::Client::Loaded,
      status : PlaceOS::Core::Client::DriverStatus? = nil
    ) : DriverStatus
      edge_modules = loaded.edge
      local_modules = loaded.local

      edges = edge_modules.map do |edge_id, processes|
        {
          edge_id, Driver.new(
            modules: processes[key]? || [] of String,
            status: status.try(&.edge[edge_id]?),
          ),
        }
      end.to_h

      DriverStatus.new(
        driver: key,
        local: Driver.new(
          modules: local_modules[key]? || [] of String,
          status: status.try(&.local),
        ),
        edge: edges,
      )
    end

    # terminates a driver on the node selected
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      @[AC::Param::Info(name: "id", description: "specifies the core node we want to send the request to")]
      core_id : String,
      @[AC::Param::Info(description: "the name of the driver to terminate")]
      driver : String
    ) : Nil
      uri = RemoteDriver.default_discovery.node_hash[core_id]
      raise Error::NotFound.new("driver not found: #{driver}") unless Core::Client.client(uri, request_id, &.terminate(driver))
    end
  end
end

class URI
  def to_json(json : JSON::Builder)
    json.string to_s
  end
end
