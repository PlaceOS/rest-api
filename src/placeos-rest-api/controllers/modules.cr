require "pinger"
require "loki-client"
require "placeos-driver/storage"
require "placeos-driver/proxy/remote_driver"

require "./application"
require "./drivers"
require "./settings"

module PlaceOS::Api
  class Modules < Application
    include Utils::CoreHelper
    include Utils::Permissions

    base "/api/engine/v2/modules/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :create, :update, :destroy, :state, :show, :ping, :start, :stop]
    before_action :check_support, only: [:state, :show, :ping, :show_error, :start, :stop]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_module(id : String)
      Log.context.set(module_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_module = ::PlaceOS::Model::Module.find!(id)
    end

    getter! current_module : ::PlaceOS::Model::Module

    # Permissions
    ###############################################################################################

    def can_modify?(mod)
      return if user_admin?
      # NOTE:: if modifying, update Settings#can_modify?

      cs_id = mod.control_system_id
      raise Error::Forbidden.new unless cs_id

      # find the org zone
      authority = current_authority.as(::PlaceOS::Model::Authority)
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      zones = ::PlaceOS::Model::ControlSystem.find!(cs_id).zones
      raise Error::Forbidden.new unless zones.includes?(org_zone_id)
      raise Error::Forbidden.new unless check_access(current_user.groups, zones).admin?
    end

    @[AC::Route::Filter(:before_action, only: [:index])]
    def check_view_permissions(
      @[AC::Param::Info(description: "only return modules running in this system (query params are ignored if this is provided)", example: "sys-1234")]
      control_system_id : String? = nil,
    )
      return if user_support?

      # find the org zone
      authority = current_authority.as(::PlaceOS::Model::Authority)
      @org_zone_id = org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      if control_system_id
        zones = ::PlaceOS::Model::ControlSystem.find!(control_system_id).zones
        raise Error::Forbidden.new unless zones.includes?(org_zone_id)
        raise Error::Forbidden.new unless check_access(current_user.groups, zones).can_manage?
      else
        access = check_access(current_user.groups, [org_zone_id])
        raise Error::Forbidden.new unless access.can_manage?
      end
    end

    getter org_zone_id : String? = nil

    # Response helpers
    ###############################################################################################

    record ControlSystemDetails, name : String, zone_data : Array(::PlaceOS::Model::Zone) do
      include JSON::Serializable
    end

    record DriverDetails, name : String, description : String?, module_name : String? do
      include JSON::Serializable
    end

    # extend the ControlSystem model to handle our return values
    class ::PlaceOS::Model::Module
      @[JSON::Field(key: "driver")]
      property driver_details : Api::Modules::DriverDetails? = nil
      @[JSON::Field(key: "control_system")]
      property control_system_details : Api::Modules::ControlSystemDetails? = nil
      property core_node : String? = nil
    end

    ###############################################################################################

    # return a list of modules configured on the cluster
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "only return modules updated before this time (unix epoch)")]
      as_of : Int64? = nil,
      @[AC::Param::Info(description: "only return modules running in this system (query params are ignored if this is provided)", example: "sys-1234")]
      control_system_id : String? = nil,
      @[AC::Param::Info(description: "only return instances of this driver", example: "driver-1234")]
      driver_id : String? = nil,
      @[AC::Param::Info(description: "do not return logic modules (return only modules that can exist in multiple systems)", example: "true")]
      no_logic : Bool = false,
      @[AC::Param::Info(description: "return only running modules", example: "true")]
      running : Bool? = nil,
    ) : Array(::PlaceOS::Model::Module)
      # if a system id is present we query the database directly
      if control_system_id
        cs = ::PlaceOS::Model::ControlSystem.find!(control_system_id)
        # Include subset of association data with results
        results = ::PlaceOS::Model::Module.find_all(cs.modules).compact_map do |mod|
          next if (driver = mod.driver).nil?

          # Most human readable module data is contained in driver
          mod.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
          mod
        end.to_a

        set_collection_headers(results.size, ::PlaceOS::Model::Module.table_name)

        return results
      end

      # we use Elasticsearch
      elastic = ::PlaceOS::Model::Module.elastic
      query = elastic.query(search_params)
      query.minimum_should_match(1)

      # TODO:: we can remove this once there is a tenant_id field on modules
      # which will make this much simpler to filter
      if filter_zone_id = org_zone_id
        # we only want to show modules in use by systems that include this zone
        no_logic = true

        # find all the non-logic modules that this user can access
        # 1. grabs all the module ids in the systems of the provided org zone
        # 2. select distinct modules ids which are not logic modules (99)
        sql_query = %[
          WITH matching_rows AS (
            SELECT unnest(modules) AS module_id
            FROM sys
            WHERE $1 = ANY(zones)
          )

          SELECT ARRAY_AGG(DISTINCT m.module_id)
          FROM matching_rows m
          JOIN mod ON m.module_id = mod.id
          WHERE mod.role <> 99;
        ]

        module_ids = PgORM::Database.connection do |conn|
          conn.query_one(sql_query, args: [filter_zone_id], &.read(Array(String)?))
        end || [] of String

        query.must({
          "id" => module_ids,
        })
      end

      if no_logic
        query.must_not({"role" => [Model::Driver::Role::Logic.to_i]})
      end

      if driver_id
        query.filter({"driver_id" => [driver_id]})
      end

      unless running.nil?
        query.should({"running" => [running]})
      end

      if as_of
        query.range({
          "updated_at" => {
            :lte => as_of,
          },
        })
      end

      query.has_parent(parent: ::PlaceOS::Model::Driver, parent_index: ::PlaceOS::Model::Driver.table_name)

      search_results = paginate_results(elastic, query)

      # Include subset of association data with results
      # avoid n+1 requests
      control_system_ids = search_results.compact_map(&.control_system_id).uniq!
      drivers = Model::Driver.find_all search_results.map(&.driver_id.as(String)).uniq!

      control_systems = Model::ControlSystem.find_all(control_system_ids).to_a
      zones = Model::Zone.find_all(control_systems.flat_map(&.zones)).to_a

      search_results.compact_map do |d|
        sys_id = d.control_system_id
        sys = sys_id ? control_systems.find { |csys| csys.id == sys_id } : nil
        d_id = d.driver_id.as(String)
        driver = drivers.find { |drive| drive.id == d_id }
        next unless driver

        # Include control system on Logic modules so it is possible
        # to display the inherited settings
        sys_field = if sys
                      ControlSystemDetails.new(sys.name, sys.zones.compact_map { |zid| zones.find { |zone| zone.id == zid } })
                    else
                      nil
                    end

        d.control_system_details = sys_field
        d.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)

        # grab connected state from redis
        d.connected = if d.running
                        storage = Driver::RedisStorage.new(d.id.as(String))
                        storage["connected"]? != "false"
                      else
                        true
                      end

        d
      end
    end

    # return the details of a module
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "return the driver details along with the module?", example: "true")]
      complete : Bool = false,
    ) : ::PlaceOS::Model::Module
      running_on = self.class.locate_module(current_module.id.as(String)) rescue nil
      current_module.core_node = running_on

      # grab connected state from redis
      current_module.connected = if current_module.running
                                   storage = Driver::RedisStorage.new(current_module.id.as(String))
                                   storage["connected"]? != "false"
                                 else
                                   true
                                 end

      if complete && (driver = current_module.driver)
        current_module.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
        if sys = current_module.control_system
          current_module.control_system_details = ControlSystemDetails.new(sys.name, ::PlaceOS::Model::Zone.find_all(sys.zones).to_a)
        end
        current_module
      else
        current_module
      end
    end

    # return runtime error log of a module (if any) or 404
    @[AC::Route::GET("/:id/error")]
    def show_error : Array(String)
      raise Error::NotFound.new("No associated error logs found for module '#{current_module.id}'") unless current_module.has_runtime_error
      error_timestamp = current_module.error_timestamp || Time.utc

      client = Loki::Client.from_env
      labels = client.list_labels.data
      stream = labels.try &.includes?("container") ? "container" : "app"
      query = %({#{stream}="core"} | source = "#{current_module.id}" |~ "(?i)exception" | level =~ "ERROR|[E]")
      results = client.query_range(query, 20, error_timestamp - 1.hour, error_timestamp, Loki::Direction::Backward)
      entries = Array(String).new
      results.response_data.result.as(Loki::Model::Streams).each do |res_stream|
        res_stream.entries.each { |entry| entries << (entry.line.try &.gsub("+ ", "") || "\n") }
      end

      entries
    end

    # update the details of a module
    @[AC::Route::PATCH("/:id", body: :mod)]
    @[AC::Route::PUT("/:id", body: :mod)]
    def update(mod : ::PlaceOS::Model::Module) : ::PlaceOS::Model::Module
      current = current_module
      can_modify?(current)
      current.assign_attributes(mod)
      can_modify?(current)

      raise Error::ModelValidation.new(current.errors) unless current.save

      if driver = current.driver
        current.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
      end
      current
    end

    # add a new module / instance of a driver
    @[AC::Route::POST("/", body: :mod, status_code: HTTP::Status::CREATED)]
    def create(mod : ::PlaceOS::Model::Module) : ::PlaceOS::Model::Module
      can_modify?(mod)
      raise Error::ModelValidation.new(mod.errors) unless mod.save
      mod
    end

    # remove a module
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      can_modify?(current_module)
      current_module.destroy
    end

    # Receive the collated settings for a module
    @[AC::Route::GET("/:id/settings")]
    def settings : Array(::PlaceOS::Model::Settings)
      Api::Settings.collated_settings(current_user, current_module)
    end

    # Starts a module
    @[AC::Route::POST("/:id/start")]
    def start : Nil
      return if current_module.running == true
      can_modify?(current_module) unless user_support?
      current_module.update_fields(running: true)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "start", module_id: current_module.id, event: "failed"} }
        raise "failed to update database to start module #{current_module.id}"
      end
    end

    # Stops a module
    @[AC::Route::POST("/:id/stop")]
    def stop : Nil
      return unless current_module.running
      can_modify?(current_module) unless user_support?
      current_module.update_fields(running: false)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "stop", module_id: current_module.id, event: "failed"} }
        raise "failed to update database to stop module #{current_module.id}"
      end
    end

    # Executes a command on a module
    # The `/systems/` route can be used to introspect modules for the list of methods and argument requirements
    @[AC::Route::POST("/:id/exec/:method", body: :args)]
    def execute(
      id : String,
      @[AC::Param::Info(description: "the name of the methodm we want to execute")]
      method : String,
      @[AC::Param::Info(description: "the arguments we want to provide to the method")]
      args : Array(JSON::Any),
    ) : Nil
      sys_id = current_module.control_system_id || ""

      result, status_code = Driver::Proxy::RemoteDriver.new(
        module_id: id,
        sys_id: sys_id,
        module_name: current_module.name,
        user_id: current_user.id,
      ) { |module_id|
        ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
      }.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )

      # customise the response based on the execute results
      response.content_type = "application/json"
      render text: result, status: status_code
    rescue e : Driver::Proxy::RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        sys_id:      sys_id,
        module_id:   id,
        module_name: current_module.name,
        method:      method,
      } }

      if Api.production?
        render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message)
      else
        render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message, backtrace: e.backtrace?)
      end
    end

    # Dumps the complete status state of the module, key values are serialised JSON
    @[AC::Route::GET("/:id/state")]
    def state : Hash(String, String)
      self.class.module_state(current_module).as(Hash(String, String))
    end

    # Returns the value of the requested status variable
    @[AC::Route::GET("/:id/state/:key")]
    def state_lookup(
      @[AC::Param::Info(description: "that name of the status we are after")]
      key : String,
    ) : String
      self.class.module_state(current_module, key).as(String)
    end

    record PingResult, host : String, pingable : Bool?, warning : String?, exception : String? do
      include JSON::Serializable
    end

    # pings the ip or hostname specified in the modules configuration
    @[AC::Route::POST("/:id/ping")]
    def ping : PingResult
      if current_module.role.logic?
        Log.debug { {controller: "Modules", action: "ping", module_id: current_module.id, role: current_module.role.to_s} }
        raise Error::ModelValidation.new({Error::Field.new(:role, "ping not supported for module role: #{current_module.role}")})
      else
        pinger = Pinger.new(current_module.hostname.as(String), count: 3)
        pinger.ping
        PingResult.new(
          host: pinger.ip.to_s,
          pingable: pinger.pingable,
          warning: pinger.warning,
          exception: pinger.exception,
        )
      end
    end

    # Loads the module if not already loaded
    # If the module is already running, it will be updated to latest settings.
    @[AC::Route::POST("/:id/load")]
    def load(id : String) : Bool
      Api::Systems.core_for(id, request_id, &.load(id))
    end

    # Helpers
    ############################################################################

    def self.driver_compiled?(mod : ::PlaceOS::Model::Module, request_id : String)
      if (driver = mod.driver).nil?
        Log.error { "failed to load Module<#{mod.id}>'s Driver<#{mod.driver_id}>" }
        return false
      end

      if (repository = driver.repository).nil?
        Log.error { "failed to load Driver<#{driver.id}>'s Repository<#{driver.repository_id}>" }
        return false
      end

      Api::Drivers.driver_compiled?(driver, repository, request_id, mod.id.as(String))
    end

    def self.module_state(mod : ::PlaceOS::Model::Module | String, key : String? = nil)
      id = mod.is_a?(String) ? mod : mod.id.as(String)
      storage = Driver::RedisStorage.new(id)
      key ? storage[key] : storage.to_h
    end

    # Use consistent hashing to determine the location of the module
    def self.locate_module(module_id : String) : String?
      node = RemoteDriver.default_discovery.find?(module_id)
      return nil unless node
      node.to_s
    end
  end
end
