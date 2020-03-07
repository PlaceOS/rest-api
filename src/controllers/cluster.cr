require "promise"
require "./application"

module ACAEngine::Api
  class Cluster < Application
    base "/api/engine/v2/cluster/"
    before_action :check_admin

    alias ClusterLoad = NamedTuple(
      hostname: String,
      cpu_count: Int32,
      core_cpu: Float64,
      total_cpu: Float64,
      memory_total: Int64,
      memory_usage: Int64,
      core_memory: Int64,
    )

    alias ClusterDetails = NamedTuple(
      compiled_drivers: Array(String),
      available_repositories: Array(String),
      running_drivers: Int32,
      module_instances: Int32,
      unavailable_repositories: Array(String),
      unavailable_drivers: Array(String),
    )

    def index
      details = {} of String => String
      Api::Systems.core_discovery.nodes.each do |node|
        details[node[:name]] = node[:uri].to_s
      end

      if params["include_status"]?
        request_id = logger.request_id || UUID.random.to_s

        # Returns [{id:, hostname:, id:, cpu_count:, core_cpu:, total_cpu:, memory_total:, memory_usage:, core_memory:}]
        render json: Promise.all(details.map { |name, host|
          Promise.defer {
            # Get the cluster details (number of drivers running, errors etc)
            response = HTTP::Client.get(
              "#{host}/api/core/v1/status/",
              headers: HTTP::Headers{"X-Request-ID" => request_id},
            )
            raise "failed to get status for #{name} => #{host}" unless response.success?
            core_overview = ClusterDetails.from_json(response.body)

            # Get the cluster load
            response = HTTP::Client.get(
              "#{host}/api/core/v1/status/load",
              headers: HTTP::Headers{"X-Request-ID" => request_id},
            )
            raise "failed to get load for #{name} => #{host}" unless response.success?
            core_load = ClusterLoad.from_json(response.body)

            core_overview.merge(core_load).merge({id: name})
          }
        }).get
      end

      # returns {"id" => "host"}
      render json: details
    end

    alias LoadedDrivers = Hash(String, Array(String))
    alias DriverStatus = NamedTuple(
      running: Bool,
      module_instances: Int32,
      last_exit_code: Int32,
      launch_count: Int32,
      launch_time: Int64,

      percentage_cpu: Float64,
      memory_total: Int64,
      memory_usage: Int64,
    )

    def show
      core_id = params["id"]

      details = {} of String => String
      Api::Systems.core_discovery.nodes.each do |node|
        details[node[:name]] = node[:uri].to_s
      end

      host = details[core_id]
      request_id = logger.request_id || UUID.random.to_s

      response = HTTP::Client.get(
        "#{host}/api/core/v1/status/loaded",
        headers: HTTP::Headers{"X-Request-ID" => request_id},
      )
      raise "failed to get processes on #{core_id} => #{host}" unless response.success?
      drivers = LoadedDrivers.from_json(response.body)

      if params["include_status"]?
        render json: Promise.all(drivers.map { |driver, modules|
          Promise.defer {
            response = HTTP::Client.get(
              "#{host}/api/core/v1/status/driver?path=#{driver}",
              headers: HTTP::Headers{"X-Request-ID" => request_id},
            )
            raise "failed to get driver status for #{core_id} => #{host} : #{driver}" unless response.success?
            driver_status = DriverStatus.from_json(response.body)

            {
              driver:  driver,
              modules: modules,
            }.merge driver_status
          }
        }).get
      end

      # returns: {"/app/bin/drivers/drivers_name_fe33588": ["mod-ETbLjPMTRfb"]}
      render json: drivers
    end

    def destroy
      core_id = params["id"]
      driver = params["driver"]

      details = {} of String => String
      Api::Systems.core_discovery.nodes.each do |node|
        details[node[:name]] = node[:uri].to_s
      end

      host = details[core_id]
      request_id = logger.request_id || UUID.random.to_s

      response = HTTP::Client.post(
        "#{host}/api/core/v1/chaos/terminate?path=#{driver}",
        headers: HTTP::Headers{"X-Request-ID" => request_id},
      )

      head response.status_code
    end
  end
end
