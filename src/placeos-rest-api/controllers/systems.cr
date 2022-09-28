require "hound-dog"

require "placeos-core-client"
require "placeos-driver/proxy/system"

require "./application"
require "./modules"
require "./settings"
require "../websocket"

module PlaceOS::Api
  class Systems < Application
    include Utils::CoreHelper

    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    base "/api/engine/v2/systems/"

    id_param :sys_id

    # Scopes
    ###############################################################################################

    # For access to the module runtime.
    generate_scope_check "control"

    # Allow unscoped access to details of a single `ControlSystem`
    before_action :can_read_guest, only: [:show, :sys_zones]

    before_action :can_read, only: [:index, :find_by_email]
    before_action :can_write, only: [:create, :update, :destroy, :remove_module, :update_alt, :start, :stop]

    before_action :can_read_control, only: [:types, :functions, :state, :state_lookup]
    before_action :can_write_control, only: [:control, :execute]

    before_action :check_admin, except: [:index, :show, :find_by_email, :control, :execute,
                                         :types, :functions, :state, :state_lookup]

    before_action :check_support, only: [:state, :state_lookup, :functions]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show, :update, :destroy, :sys_zones, :settings, :add_module, :remove_module, :start, :stop])]
    def find_current_control_system(
      sys_id : String
    )
      Log.context.set(control_system_id: sys_id)
      # Find will raise a 404 (not found) if there is an error
      @current_control_system = Model::ControlSystem.find!(sys_id, runopts: {"read_mode" => "majority"})
    end

    getter! current_control_system : Model::ControlSystem

    # Response helpers
    ###############################################################################################

    # extend the ControlSystem model to handle our return values
    class Model::ControlSystem
      @[JSON::Field(key: "zone_data")]
      property zone_data_details : Array(Model::Zone)? = nil

      @[JSON::Field(key: "module_data")]
      property module_data_details : Array(Model::Module)? = nil
    end

    ###############################################################################################

    # Websocket API session manager
    class_getter session_manager : WebSocket::Manager { WebSocket::Manager.new(core_discovery) }

    # Query ControlSystem resources
    @[AC::Route::GET("/", converters: {features: ConvertStringArray, email: ConvertStringArray})]
    def index(
      bookable : Bool? = nil,
      capacity : Int32? = nil,
      email : Array(String)? = nil,
      features : Array(String)? = nil,
      module_id : String? = nil,
      trigger_id : String? = nil,
      zone_id : String? = nil,
    ) : Array(Model::ControlSystem)
      elastic = Model::ControlSystem.elastic
      query = Model::ControlSystem.elastic.query(search_params)

      # Filter systems by zone_id
      if zone_id
        query.must({
          "zones" => [zone_id],
        })
      end

      # Filter by module_id
      if module_id
        query.must({
          "modules" => [module_id],
        })
      end

      # Filter by trigger_id
      if trigger_id
        query.has_child(Model::TriggerInstance)
        query.must({
          "trigger_id" => [trigger_id],
        })
      end

      # Filter by features
      if features
        query.must({
          "features" => features,
        })
      end

      # filter by capacity
      if capacity
        query.range({
          "capacity" => {
            :gte => capacity,
          },
        })
      end

      # filter by bookable
      unless bookable.nil?
        query.must({
          "bookable" => [bookable],
        })
      end

      # filter by emails
      if email
        query.should({
          "email" => email,
        })
      end

      query.search_field "name"
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # Finds all the systems with the specified email address
    @[AC::Route::GET("/with_emails", converters: {emails: ConvertStringArray})]
    def find_by_email(
      @[AC::Param::Info(name: "in", description: "comma seperated list of emails", example: "room1@org.com,room2@org.com")]
      emails : Array(String)
    ) : Array(Model::ControlSystem)
      systems = Model::ControlSystem.find_all(emails, index: :email).to_a
      set_collection_headers(systems.size, Model::ControlSystem.table_name)
      systems
    end

    # Renders a control system
    @[AC::Route::GET("/:sys_id")]
    def show(
      complete : Bool = false
    ) : Model::ControlSystem
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        raise Error::Forbidden.new unless user_token.user.roles.includes?(current_control_system.id)
        return current_control_system
      end

      if complete
        sys = current_control_system
        sys.zone_data_details = Model::Zone.find_all(current_control_system.zones).to_a

        # extend the module details with the driver details
        modules = Model::Module.find_all(current_control_system.modules).to_a.map do |mod|
          # Pick off driver name, and module_name from associated driver
          mod.driver_details = mod.driver.try do |driver|
            Api::Modules::DriverDetails.new(driver.name, driver.description, driver.module_name)
          end
          mod
        end
        sys.module_data_details = modules

        sys
      else
        current_control_system
      end
    end

    # Updates a control system
    @[AC::Route::PATCH("/:sys_id", body: :sys)]
    @[AC::Route::PUT("/:sys_id", body: :sys)]
    def update(
      sys : Model::ControlSystem,
      version : Int32
    ) : Model::ControlSystem
      if version != current_control_system.version
        raise Error::Conflict.new("Attempting to edit an old System version")
      end

      current = current_control_system
      current.assign_attributes(sys)
      current.version = version + 1
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::POST("/", body: :sys, status_code: HTTP::Status::CREATED)]
    def create(sys : Model::ControlSystem) : Model::ControlSystem
      raise Error::ModelValidation.new(sys.errors) unless sys.save
      sys
    end

    @[AC::Route::DELETE("/:sys_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      cs_id = current_control_system.id
      current_control_system.destroy
      spawn { Api::Metadata.signal_metadata(:destroy_all, {parent_id: cs_id}) }
    end

    # Return all zones for this system
    @[AC::Route::GET("/:sys_id/zones")]
    def sys_zones : Array(Model::Zone)
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        raise Error::Forbidden.new unless user_token.user.roles.includes?(current_control_system.id)
      end

      # Save the DB hit if there are no zones on the system
      documents = if current_control_system.zones.empty?
                    [] of Model::Zone
                  else
                    Model::Zone.find_all(current_control_system.zones).to_a
                  end

      set_collection_headers(documents.size, Model::Zone.table_name)

      documents
    end

    # Return metadata for the system
    @[AC::Route::GET("/:sys_id/metadata")]
    def metadata(
      sys_id : String,
      name : String? = nil
    ) : Hash(String, PlaceOS::Model::Metadata::Interface)
      Model::Metadata.build_metadata(sys_id, name)
    end

    # Receive the collated settings for a system
    @[AC::Route::GET("/:sys_id/settings")]
    def settings : Array(PlaceOS::Model::Settings)
      Api::Settings.collated_settings(current_user, current_control_system)
    end

    # Adds the module from the system if it doesn't already exist
    @[AC::Route::PUT("/:sys_id/module/:module_id")]
    def add_module(
      module_id : String
    ) : Model::ControlSystem
      raise Error::NotFound.new unless Model::Module.exists?(module_id)

      module_present = current_control_system.modules.includes?(module_id) || Model::ControlSystem.add_module(current_control_system.id.as(String), module_id)
      raise "Failed to add ControlSystem Module" unless module_present

      # Return the latest version of the control system
      Model::ControlSystem.find!(current_control_system.id.as(String), runopts: {"read_mode" => "majority"})
    end

    # Removes the module from the system and deletes it if not used elsewhere
    @[AC::Route::DELETE("/:sys_id/module/:module_id", status_code: HTTP::Status::ACCEPTED)]
    def remove_module(
      module_id : String
    ) : Model::ControlSystem
      if current_control_system.modules.includes?(module_id)
        current_control_system.remove_module(module_id)
        raise Error::ModelValidation.new(current_control_system.errors) unless current_control_system.save
      end

      current_control_system
    end

    # Module Functions
    ###########################################################################

    # Start modules
    @[AC::Route::POST("/:sys_id/start")]
    def start : Nil
      Systems.module_running_state(running: true, control_system: current_control_system)
    end

    # Stop modules
    @[AC::Route::POST("/:sys_id/stop")]
    def stop : Nil
      Systems.module_running_state(running: false, control_system: current_control_system)
    end

    # Toggle the running state of ControlSystem's Module
    #
    protected def self.module_running_state(control_system : Model::ControlSystem, running : Bool)
      Model::Module.table_query do |q|
        q
          .get_all(control_system.modules)
          .filter({ignore_startstop: false})
          .update({running: running})
      end
    end

    # Driver Metadata, State and Status
    ###########################################################################

    # Runs a function in a system module
    @[AC::Route::POST("/:sys_id/:module_slug/:method", body: :args)]
    def execute(
      sys_id : String,
      module_slug : String,
      method : String,
      args : Array(JSON::Any)
    ) : Nil
      module_name, index = RemoteDriver.get_parts(module_slug)
      Log.context.set(module_name: module_name, index: index, method: method)

      remote_driver = RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        discovery: self.class.core_discovery,
        user_id: current_user.id,
      )

      response_text, status_code = remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )
      response.headers["Content-Type"] = "application/json"
      render text: response_text, status: status_code
    rescue e : RemoteDriver::Error
      handle_execute_error(e)
    end

    # Look-up a module types in a system, returning a count of each type
    @[AC::Route::GET("/:sys_id/types")]
    def types(sys_id : String) : Hash(String, Int32)
      Model::Module
        .in_control_system(sys_id)
        .tally_by(&.resolved_name)
    end

    # Returns the state of an associated module
    @[AC::Route::GET("/:sys_id/:module_slug")]
    def state(
      sys_id : String,
      module_slug : String,
    ) : Hash(String, String)
      module_name, index = RemoteDriver.get_parts(module_slug)
      self.class.module_state(sys_id, module_name, index) || {} of String => String
    end

    # Returns the state lookup for a given key on a module
    @[AC::Route::GET("/:sys_id/:module_slug/:key")]
    def state_lookup(
      sys_id : String,
      module_slug : String,
      key : String,
    ) : String?
      module_name, index = RemoteDriver.get_parts(module_slug)
      self.class.module_state(sys_id, module_name, index, key).as(String?)
    end

    record FunctionDetails, arity : Int32, params : Hash(String, JSON::Any), order : Array(String) do
      include JSON::Serializable
    end

    # Lists functions available on the driver
    # Filters higher privilege functions.
    @[AC::Route::GET("/:sys_id/functions/:module_slug")]
    def functions(
      sys_id : String,
      module_slug : String,
    ) : Hash(String, FunctionDetails)
      module_name, index = RemoteDriver.get_parts(module_slug)
      metadata = ::PlaceOS::Driver::Proxy::System.driver_metadata?(
        system_id: sys_id,
        module_name: module_name,
        index: index,
      )

      unless metadata
        message = "metadata not found for #{module_slug} on #{sys_id}"
        Log.debug { message }
        raise Error::NotFound.new(message)
      end

      hidden_functions = if user_token.is_admin?
                           # All functions available to admin
                           [] of String
                         elsif user_token.is_support?
                           # Admin functions hidden from support
                           metadata.security["administrator"]? || [] of String
                         else
                           # All privileged functions hidden from user without privileges
                           (metadata.security["support"]? || [] of String) + (metadata.security["administrator"]? || [] of String)
                         end

      # Delete keys to metadata for functions with higher privilege
      functions = metadata.interface.reject!(hidden_functions)

      # Transform function metadata
      functions.transform_values do |arguments|
        FunctionDetails.new(
          arity:  arguments.size,
          params: arguments,
          order:  arguments.keys,
        )
      end
    end

    def self.module_state(sys_id : String, module_name : String, index : Int32, key : String? = nil)
      # Look up module's id for module on system
      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: sys_id,
        module_name: module_name,
        index: index
      )

      Modules.module_state(module_id, key) if module_id
    end

    # Websocket API
    ###########################################################################

    @[AC::Route::WebSocket("/control")]
    def control(ws, fixed_device : Bool = false) : Nil
      Log.trace { "WebSocket API request" }
      Log.context.set(fixed_device: fixed_device)
      Systems.session_manager.create_session(
        ws: ws,
        request_id: request_id,
        user: user_token,
      )
    end

    # Helpers
    ###########################################################################

    # Use consistent hashing to determine the location of the module
    def self.locate_module(module_id : String) : URI
      node = core_discovery.find?(module_id)
      raise "no core instances registered!" unless node
      node[:uri]
    end

    # Determine URI for a system module
    def self.locate_module?(sys_id : String, module_name : String, index : Int32) : URI?
      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(sys_id, module_name, index)
      module_id.try &->self.locate_module(String)
    end

    # Create a core client for given module id
    def self.core_for(module_id : String, request_id : String? = nil) : Core::Client
      Core::Client.new(uri: self.locate_module(module_id), request_id: request_id)
    end

    # Create a core client and yield it to a block
    def self.core_for(module_id : String, request_id : String? = nil, & : Core::Client -> V) forall V
      Core::Client.client(uri: self.locate_module(module_id), request_id: request_id) do |client|
        yield client
      end
    end
  end
end
