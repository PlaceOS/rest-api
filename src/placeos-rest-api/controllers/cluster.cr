require "promise"
require "./application"

require "placeos-core/client"

module PlaceOS::Api
  class Cluster < Application
    base "/api/engine/v2/cluster/"
    before_action :check_admin

    def index
      details = self.class.core_discovery.node_hash

      if params.["include_status"]?
        promises = details.map do |name, uri|
          Promise.defer do
            begin
              {
                name,
                {
                  status: Cluster.node_status(name, uri, request_id),
                  uri:    uri,
                },
              }
            rescue
              nil
            end
          end
        end

        # {
        #   <id>: {
        #     "load": <load>,
        #     "status": <status>,
        #     "uri": <uri>,
        #     "id": <id>
        #   }
        # }
        render json: Promise.all(promises).get.compact.to_h
      else
        # { <id>: { "uri": <uri>, "id": <id> } }
        details = details.map { |id, uri| ({id, {id: id, uri: uri}}) }.to_h
        render json: details
      end
    end

    alias NodeStatus = NamedTuple(
      id: String,
      uri: URI,
      # Get the cluster load
      load: PlaceOS::Core::Client::Load,
      # Get the cluster details (number of drivers running, errors etc)
      status: PlaceOS::Core::Client::CoreStatus,
    )

    def self.node_status(name : String, uri : URI, request_id : String) : NodeStatus
      Core::Client.client(uri, request_id) do |client|
        {
          id:  name,
          uri: uri,
          # Get the cluster load
          load: client.core_load,
          # Get the cluster details (number of drivers running, errors etc)
          status: client.core_status,
        }
      end
    end

    # Collect unique driver keys managed by a node
    #
    def self.collect_keys(loaded : PlaceOS::Core::Client::Loaded)
      # Retain only the driver key
      loaded.edge
        .values.flat_map(&.keys)
        .concat(loaded.local.keys)
        .map { |k| k.split('/').last }
        .to_set
    end

    def show
      include_status = !!params["include_status"]?
      core_id = params["id"]
      uri = self.class.core_discovery.node_hash[core_id]
      Core::Client.client(uri, request_id) do |client|
        loaded = client.loaded

        # Collect unique driver keys managed by node
        driver_keys = Cluster.collect_keys(loaded)

        if include_status
          promises = driver_keys.map do |key|
            Promise.defer do
              begin
                {key, Cluster.driver_status(key, loaded, client.driver_status(key))}
              rescue
                nil
              end
            end
          end

          # {
          #   <driver_key>: {
          #     "local": { "modules": [<module_id>], "status": <driver_status> }
          #     "edge": {
          #       <edge_id>: { "modules": [<module_id>], "status": <driver_status> }
          #     }
          #   }
          # }
          render json: Promise.all(promises).get.compact.to_h
        else
          # {
          #   <driver_key>: {
          #     "local": { "modules": [<module_id>] }
          #     "edge": {
          #       <edge_id>: { "modules": [<module_id>] }
          #     }
          #   }
          # }
          render json: driver_keys.map { |key| {key, Cluster.driver_status(key, loaded)} }.to_h
        end
      end
    end

    alias Driver = NamedTuple(modules: Array(String), status: PlaceOS::Core::Client::DriverStatus::Metadata?)
    alias DriverStatus = NamedTuple(local: Driver, edge: Hash(String, Driver))

    def self.driver_status(
      key : String,
      loaded : PlaceOS::Core::Client::Loaded,
      status : PlaceOS::Core::Client::DriverStatus? = nil
    ) : DriverStatus
      edge_modules = loaded.edge
      local_modules = loaded.local

      edges = edge_modules.map do |edge_id, processes|
        {
          edge_id, {
            modules: processes[key],
            status:  status.try(&.edge[edge_id]?),
          }.as(Driver),
        }
      end.to_h

      {
        local: {
          modules: local_modules[key],
          status:  status.try(&.local),
        }.as(Driver),
        edge: edges,
      }
    end

    def destroy
      core_id = params["id"]
      driver = params["driver"]

      uri = self.class.core_discovery.node_hash[core_id]
      if Core::Client.client(uri, request_id) { |client| client.terminate(driver) }
        head :ok
      else
        head :not_found
      end
    end
  end
end

class URI
  def to_json(json : JSON::Builder)
    json.string to_s
  end
end
