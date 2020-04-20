require "promise"
require "./application"

module PlaceOS::Api
  class Cluster < Application
    base "/api/engine/v2/cluster/"
    before_action :check_admin

    def index
      details = Api::Systems.core_discovery.node_hash

      if params["include_status"]?
        request_id = logger.request_id || UUID.random.to_s

        # Returns Array(NodeStatus)
        render json: Promise.all(details.map { |name, uri|
          Promise.defer { Cluster.node_status(name, uri, request_id) }
        }).get
      end

      # returns {"id" => "host"}
      render json: details
    end

    alias NodeStatus = NamedTuple(
      id: String,
      hostname: String,
      cpu_count: Int32,
      core_cpu: Float64,
      total_cpu: Float64,
      memory_total: Int64,
      memory_usage: Int64,
      core_memory: Int64,
      compiled_drivers: Array(String),
      available_repositories: Array(String),
      running_drivers: Int32,
      module_instances: Int32,
      unavailable_repositories: Array(NodeError),
      unavailable_drivers: Array(NodeError),
    )

    alias NodeError = NamedTuple(name: String, reason: String)

    def self.node_status(name : String, uri : URI, request_id : String) : NodeStatus
      Core::Client.client(uri, request_id) do |client|
        # Get the cluster details (number of drivers running, errors etc)
        core_status = client.core_status
        # Get the cluster load
        core_load = client.core_load

        {
          id:                       name,
          hostname:                 core_load.hostname.to_s,
          cpu_count:                core_load.cpu_count,
          core_cpu:                 core_load.core_cpu,
          total_cpu:                core_load.total_cpu,
          memory_total:             core_load.memory_total,
          memory_usage:             core_load.memory_usage,
          core_memory:              core_load.core_memory,
          compiled_drivers:         core_status.compiled_drivers,
          available_repositories:   core_status.available_repositories,
          running_drivers:          core_status.running_drivers,
          module_instances:         core_status.module_instances,
          unavailable_repositories: core_status.unavailable_repositories,
          unavailable_drivers:      core_status.unavailable_drivers,
        }
      end
    end

    alias LoadedDrivers = Hash(String, Array(String))
    alias DriverStatus = NamedTuple(
      running: Bool,
      module_instances: Int32,
      last_exit_code: Int32,
      launch_count: Int32,
      launch_time: Int64,

      # These will not be available if running == false
      percentage_cpu: Float64?,
      memory_total: Int64?,
      memory_usage: Int64?,
    )

    def show
      core_id = params["id"]

      uri = Api::Systems.core_discovery.node_hash[core_id]
      request_id = logger.request_id || UUID.random.to_s

      Core::Client.client(uri, request_id) do |client|
        drivers = client.loaded

        if params["include_status"]?
          render json: Promise.all(drivers.map { |driver, modules|
            Promise.defer { Cluster.driver_status(driver, modules, client) }
          }).get
        else
          # returns: {"/app/bin/drivers/drivers_name_fe33588": ["mod-ETbLjPMTRfb"]}
          render json: drivers
        end
      end
    end

    def self.driver_status(driver_path, modules, client : Core::Client)
      driver_status = client.driver_status(driver_path)
      {
        running:          driver_status.running,
        module_instances: driver_status.module_instances,
        last_exit_code:   driver_status.last_exit_code,
        launch_count:     driver_status.launch_count,
        launch_time:      driver_status.launch_time,
        percentage_cpu:   driver_status.percentage_cpu,
        memory_total:     driver_status.memory_total,
        memory_usage:     driver_status.memory_usage,
        driver:           driver_path,
        modules:          modules,
      }
    end

    def destroy
      core_id = params["id"]
      driver = params["driver"]

      uri = Api::Systems.core_discovery.node_hash[core_id]
      request_id = logger.request_id || UUID.random.to_s

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
