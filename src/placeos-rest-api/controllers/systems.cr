require "placeos-core-client"
require "placeos-driver/proxy/system"

require "./application"
require "./modules"
require "./settings"
require "../websocket"

module PlaceOS::Api
  class Systems < Application
    include Utils::CoreHelper
    include Utils::Permissions

    base "/api/engine/v2/systems/"

    # Scopes
    ###############################################################################################

    # For access to the module runtime.
    generate_scope_check "control"

    # Allow unscoped access to details of a single `ControlSystem`
    before_action :can_read_guest, only: [:show, :sys_zones]

    before_action :can_read, only: [:index, :find_by_email]
    before_action :can_write, only: [:create, :update, :destroy, :remove_module, :start, :stop]

    before_action :can_read_control, only: [:types, :functions, :state, :state_lookup]
    before_action :can_write_control, only: [:control, :execute]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show, :update, :destroy, :sys_zones, :settings, :add_module, :remove_module, :start, :stop])]
    def find_current_control_system(
      sys_id : String
    )
      Log.context.set(control_system_id: sys_id)
      # Find will raise a 404 (not found) if there is an error
      if sys_id.includes?('@')
        systems = find_by_email([sys_id])
        if systems.size > 0
          @current_control_system = systems.first
        else
          raise Error::NotFound.new("no system with email: #{sys_id}")
        end
      else
        @current_control_system = ::PlaceOS::Model::ControlSystem.find!(sys_id)
      end
    end

    getter! current_control_system : ::PlaceOS::Model::ControlSystem

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :control_system_update)]
    def parse_update_control_system(@control_system_update : ::PlaceOS::Model::ControlSystem)
    end

    getter! control_system_update : ::PlaceOS::Model::ControlSystem

    # Permissions
    ###############################################################################################

    before_action :check_admin, except: [
      :index, :show, :find_by_email, :control, :execute, :types,
      :destroy, :update, :create, :add_module, :remove_module,
      :state, :state_lookup, :functions,
    ]

    before_action :check_support, only: [
      :state, :state_lookup, :functions,
    ]

    @[AC::Route::Filter(:before_action, only: [:destroy, :add_module, :remove_module])]
    def check_admin_permissions
      return if user_admin?
      check_access_level(current_control_system.zones, admin_required: true)
    end

    @[AC::Route::Filter(:before_action, only: [:update])]
    def check_update_permissions
      return if user_support?
      check_access_level(current_control_system.zones, admin_required: false)
      check_access_level(control_system_update.zones, admin_required: false)
    end

    @[AC::Route::Filter(:before_action, only: [:create])]
    def check_create_permissions
      return if user_support?
      check_access_level(control_system_update.zones, admin_required: false)
    end

    def check_access_level(zones : Array(String), admin_required : Bool = false)
      # find the org zone
      authority = current_authority.as(::PlaceOS::Model::Authority)
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      # ensure the system is part of the organisation
      if zones.includes? org_zone_id
        access = check_access(current_user.groups, zones)

        if admin_required
          return if access.admin?
        else
          return if access.can_manage?
        end
      end

      raise Error::Forbidden.new
    end

    # Response helpers
    ###############################################################################################

    # extend the ControlSystem model to handle our return values
    class ::PlaceOS::Model::ControlSystem
      @[JSON::Field(key: "zone_data")]
      property zone_data_details : Array(::PlaceOS::Model::Zone)? = nil

      @[JSON::Field(key: "module_data")]
      property module_data_details : Array(::PlaceOS::Model::Module)? = nil

      # source => list of playlists
      # i.e. zone-xyz => ["playlist-1", "playlist-2"]
      @[JSON::Field(key: "playlist_mappings")]
      property playlist_mappings : Hash(String, Array(String))? = nil

      # playlist-1 => [configuration, media list]
      @[JSON::Field(key: "playlist_config")]
      property playlist_config : Hash(String, Tuple(::PlaceOS::Model::Playlist, Array(String)))? = nil

      # media details (for caching)
      @[JSON::Field(key: "playlist_media")]
      property playlist_media : Array(::PlaceOS::Model::Playlist::Item)? = nil
    end

    ###############################################################################################

    # Websocket API session manager
    class_getter session_manager : WebSocket::Manager { WebSocket::Manager.new(RemoteDriver.default_discovery) }

    # list the systems in a cluster
    @[AC::Route::GET("/", converters: {features: ConvertStringArray, email: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "return only bookable or non-bookable rooms (returns both when not specified)", example: "true")]
      bookable : Bool? = nil,
      @[AC::Param::Info(description: "return only rooms with capacity equal or greater than that provided", example: "5")]
      capacity : Int32? = nil,
      @[AC::Param::Info(description: "return only systems whos resource address match one of the emails provided", example: "room@org.com,room2@org.com")]
      email : Array(String)? = nil,
      @[AC::Param::Info(description: "return only rooms who have all of the features requested", example: "whiteboard,vidconf,display")]
      features : Array(String)? = nil,
      @[AC::Param::Info(description: "return only systems which have the module id provided", example: "mod-1234")]
      module_id : String? = nil,
      @[AC::Param::Info(description: "return systems which are using the trigger id provided", example: "trig-1234")]
      trigger_id : String? = nil,
      @[AC::Param::Info(description: "return systems which are in the zone provided", example: "zone-1234")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "return systems which are public", example: "true")]
      public : Bool? = nil,
      @[AC::Param::Info(description: "return systems which are signage", example: "true")]
      signage : Bool? = nil
    ) : Array(::PlaceOS::Model::ControlSystem)
      elastic = ::PlaceOS::Model::ControlSystem.elastic
      query = ::PlaceOS::Model::ControlSystem.elastic.query(search_params)

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
        query.has_child(::PlaceOS::Model::TriggerInstance)
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

      # filter by public
      if public
        query.should({
          "public" => [true],
        })
      end

      # filter by signage
      if public
        query.should({
          "signage" => [true],
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
    ) : Array(::PlaceOS::Model::ControlSystem)
      systems = ::PlaceOS::Model::ControlSystem.where(email: emails.map(&.strip.downcase)).to_a
      set_collection_headers(systems.size, ::PlaceOS::Model::ControlSystem.table_name)
      systems
    end

    # Renders a control system
    @[AC::Route::GET("/:sys_id")]
    def show(
      @[AC::Param::Info(description: "return the system with the zone, module and driver information collected", example: "true")]
      complete : Bool = false
    ) : ::PlaceOS::Model::ControlSystem
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        raise Error::Forbidden.new unless user_token.user.roles.includes?(current_control_system.id)
        return current_control_system
      end

      if complete
        sys = current_control_system
        sys.zone_data_details = ::PlaceOS::Model::Zone.find_all(current_control_system.zones).to_a

        # extend the module details with the driver details
        modules = ::PlaceOS::Model::Module.find_all(current_control_system.modules).to_a.map do |mod|
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
    @[AC::Route::PATCH("/:sys_id")]
    @[AC::Route::PUT("/:sys_id")]
    def update(
      @[AC::Param::Info(description: "must be provided to prevent overwriting newer config with old, in the case where multiple people might be editing a system", example: "3")]
      version : Int32
    ) : ::PlaceOS::Model::ControlSystem
      if version != current_control_system.version
        raise Error::Conflict.new("Attempting to edit an old System version")
      end

      updated = control_system_update
      current = current_control_system
      current.assign_attributes(updated)
      current.version = version + 1
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new system
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::ControlSystem
      sys = control_system_update
      raise Error::ModelValidation.new(sys.errors) unless sys.save
      sys
    end

    # removes a system, also destroys all the modules in the system that are not in any other systems
    @[AC::Route::DELETE("/:sys_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      cs_id = current_control_system.id
      current_control_system.destroy
      spawn { Api::Metadata.signal_metadata(:destroy_all, {parent_id: cs_id}) }
    end

    # Return all zones for this system
    @[AC::Route::GET("/:sys_id/zones")]
    def sys_zones : Array(::PlaceOS::Model::Zone)
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        raise Error::Forbidden.new unless user_token.user.roles.includes?(current_control_system.id)
      end

      # Save the DB hit if there are no zones on the system
      documents = if current_control_system.zones.empty?
                    [] of ::PlaceOS::Model::Zone
                  else
                    ::PlaceOS::Model::Zone.find_all(current_control_system.zones).to_a
                  end

      set_collection_headers(documents.size, ::PlaceOS::Model::Zone.table_name)

      documents
    end

    # Return metadata for the system
    @[AC::Route::GET("/:sys_id/metadata")]
    def metadata(
      sys_id : String,
      name : String? = nil
    ) : Hash(String, ::PlaceOS::Model::Metadata::Interface)
      ::PlaceOS::Model::Metadata.build_metadata(sys_id, name)
    end

    # Receive the collated settings for a system
    @[AC::Route::GET("/:sys_id/settings")]
    def settings : Array(::PlaceOS::Model::Settings)
      Api::Settings.collated_settings(current_user, current_control_system)
    end

    # Adds the module to the system if it doesn't already exist
    @[AC::Route::PUT("/:sys_id/module/:module_id")]
    def add_module(
      module_id : String
    ) : ::PlaceOS::Model::ControlSystem
      raise Error::NotFound.new unless ::PlaceOS::Model::Module.exists?(module_id)

      module_present = current_control_system.modules.includes?(module_id) || ::PlaceOS::Model::ControlSystem.add_module(current_control_system.id.as(String), module_id)
      raise "Failed to add ControlSystem Module" unless module_present

      # Return the latest version of the control system
      ::PlaceOS::Model::ControlSystem.find!(current_control_system.id.as(String))
    end

    # Removes the module from the system and deletes it if not used elsewhere
    @[AC::Route::DELETE("/:sys_id/module/:module_id", status_code: HTTP::Status::ACCEPTED)]
    def remove_module(
      module_id : String
    ) : ::PlaceOS::Model::ControlSystem
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
    protected def self.module_running_state(control_system : ::PlaceOS::Model::ControlSystem, running : Bool)
      ::PlaceOS::Model::Module.where(id: control_system.modules, ignore_startstop: false).update_all(running: running)
    end

    # Driver Metadata, State and Status
    ###########################################################################

    # Runs a function in a system module
    @[AC::Route::POST("/:sys_id/:module_slug/:method", body: :args)]
    def execute(
      sys_id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String,
      @[AC::Param::Info(description: "the method to execute on the module", example: "power")]
      method : String,
      args : Array(JSON::Any)
    ) : Nil
      module_name, index = RemoteDriver.get_parts(module_slug)
      Log.context.set(module_name: module_name, index: index, method: method)

      remote_driver = RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        user_id: current_user.id,
      ) { |module_id|
        ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
      }

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
    rescue e
      render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message, backtrace: e.backtrace)
    end

    # Look-up a module types in a system, returning a count of each type
    @[AC::Route::GET("/:sys_id/types")]
    def types(sys_id : String) : Hash(String, Int32)
      ::PlaceOS::Model::Module
        .in_control_system(sys_id)
        .tally_by(&.resolved_name)
    end

    # Returns the state of an associated module
    @[AC::Route::GET("/:sys_id/:module_slug")]
    def state(
      sys_id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String
    ) : Hash(String, String)
      module_name, index = RemoteDriver.get_parts(module_slug)
      self.class.module_state(sys_id, module_name, index) || {} of String => String
    end

    # Returns the state lookup for a given key on a module
    @[AC::Route::GET("/:sys_id/:module_slug/:key")]
    def state_lookup(
      sys_id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String,
      @[AC::Param::Info(description: "the status key we are interested in", example: "power_state")]
      key : String
    ) : JSON::Any
      module_name, index = RemoteDriver.get_parts(module_slug)
      JSON.parse(self.class.module_state(sys_id, module_name, index, key).as(String?) || "null")
    end

    record FunctionDetails, arity : Int32, params : Hash(String, JSON::Any), order : Array(String) do
      include JSON::Serializable
    end

    # Lists functions available on the driver
    # Filters higher privilege functions.
    @[AC::Route::GET("/:sys_id/functions/:module_slug")]
    def functions(
      sys_id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String
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
          arity: arguments.size,
          params: arguments,
          order: arguments.keys,
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

    # the websocket API endpoint
    # use this to interact with systems and modules efficiently
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
      node = RemoteDriver.default_discovery.find?(module_id)
      raise "no core instances registered!" unless node
      node
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
