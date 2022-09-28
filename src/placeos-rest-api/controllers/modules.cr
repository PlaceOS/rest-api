require "pinger"
require "placeos-driver/storage"

require "./application"
require "./drivers"
require "./settings"

module PlaceOS::Api
  class Modules < Application
    include Utils::CoreHelper

    base "/api/engine/v2/modules/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :state, :show, :ping]
    before_action :check_support, only: [:index, :state, :show, :ping]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_module(id : String)
      Log.context.set(module_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_module = Model::Module.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_module : Model::Module

    # Response helpers
    ###############################################################################################

    record ControlSystemDetails, name : String, zone_data : Array(Model::Zone) do
      include JSON::Serializable
    end

    record DriverDetails, name : String, description : String?, module_name : String? do
      include JSON::Serializable
    end

    # extend the ControlSystem model to handle our return values
    class Model::Module
      @[JSON::Field(key: "driver")]
      property driver_details : Api::Modules::DriverDetails? = nil
      property compiled : Bool? = nil
      @[JSON::Field(key: "control_system")]
      property control_system_details : Api::Modules::ControlSystemDetails? = nil
    end

    ###############################################################################################

    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "only return modules updated before this time (unix epoch)")]
      as_of : Int64? = nil,
      @[AC::Param::Info(description: "only return modules running in this system (query params are ignored if this is provided)", example: "sys-1234")]
      control_system_id : String? = nil,
      @[AC::Param::Info(description: "only return modules with a particular connected state", example: "true")]
      connected : Bool? = nil,
      @[AC::Param::Info(description: "only return instances of this driver", example: "driver-1234")]
      driver_id : String? = nil,
      @[AC::Param::Info(description: "do not return logic modules (return only modules that can exist in multiple systems)", example: "true")]
      no_logic : Bool = false,
      @[AC::Param::Info(description: "return only running modules", example: "true")]
      running : Bool? = nil
    ) : Array(Model::Module)
      # if a system id is present we query the database directly
      if control_system_id
        cs = Model::ControlSystem.find!(control_system_id)
        # Include subset of association data with results
        results = Model::Module.find_all(cs.modules).compact_map do |mod|
          next if (driver = mod.driver).nil?

          # Most human readable module data is contained in driver
          mod.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
          mod.compiled = Api::Modules.driver_compiled?(mod, request_id)
          mod
        end.to_a

        set_collection_headers(results.size, Model::Module.table_name)

        results
      else # we use Elasticsearch
        elastic = Model::Module.elastic
        query = elastic.query(search_params)

        if driver_id
          query.filter({"driver_id" => [driver_id]})
        end

        unless connected.nil?
          query.filter({
            "ignore_connected" => [false],
            "connected"        => [connected],
          })
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

        if no_logic
          query.must_not({"role" => [Model::Driver::Role::Logic.to_i]})
        end

        query.has_parent(parent: Model::Driver, parent_index: Model::Driver.table_name)

        search_results = paginate_results(elastic, query)

        # Include subset of association data with results
        search_results.compact_map do |d|
          sys = d.control_system
          driver = d.driver
          next unless driver

          # Include control system on Logic modules so it is possible
          # to display the inherited settings
          sys_field = if sys
                        ControlSystemDetails.new(sys.name, Model::Zone.find_all(sys.zones).to_a)
                      else
                        nil
                      end

          d.control_system_details = sys_field
          d.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
          d
        end
      end
    end

    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "return the driver details along with the module?", example: "true")]
      complete : Bool = false
    ) : Model::Module
      if complete && (driver = current_module.driver)
        current_module.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
        current_module
      else
        current_module
      end
    end

    @[AC::Route::PATCH("/:id", body: :mod)]
    @[AC::Route::PUT("/:id", body: :mod)]
    def update(mod : Model::Module) : Model::Module
      current = current_module
      current.assign_attributes(mod)
      raise Error::ModelValidation.new(current.errors) unless current.save

      if driver = current.driver
        current.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
      end
      current
    end

    @[AC::Route::POST("/", body: :mod, status_code: HTTP::Status::CREATED)]
    def create(mod : Model::Module) : Model::Module
      raise Error::ModelValidation.new(mod.errors) unless mod.save
      mod
    end

    def destroy : Nil
      current_module.destroy
    end

    # Receive the collated settings for a module
    @[AC::Route::GET("/:id/settings")]
    def settings : Array(PlaceOS::Model::Settings)
      Api::Settings.collated_settings(current_user, current_module)
    end

    # Starts a module
    @[AC::Route::POST("/:id/start")]
    def start : Nil
      return if current_module.running == true
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
      current_module.update_fields(running: false)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "stop", module_id: current_module.id, event: "failed"} }
        raise "failed to update database to stop module #{current_module.id}"
      end
    end

    # Executes a command on a module
    @[AC::Route::POST("/:id/exec/:method", body: :args)]
    def execute(id : String, method : String, args : Array(JSON::Any)) : Nil
      sys_id = current_module.control_system_id || ""

      result, status_code = Driver::Proxy::RemoteDriver.new(
        module_id: id,
        sys_id: sys_id,
        module_name: current_module.name,
        discovery: self.class.core_discovery,
        user_id: current_user.id,
      ).exec(
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
      key : String
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

    def self.driver_compiled?(mod : Model::Module, request_id : String)
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

    def self.module_state(mod : Model::Module | String, key : String? = nil)
      id = mod.is_a?(String) ? mod : mod.id.as(String)
      storage = Driver::RedisStorage.new(id)
      key ? storage[key] : storage.to_h
    end
  end
end
