require "hound-dog"

require "engine-core/client"
require "engine-driver/proxy/system"

require "./application"
require "../session"

module ACAEngine::Api
  class Systems < Application
    base "/api/engine/v2/systems/"

    id_param :sys_id

    before_action :check_admin, except: [:index, :show, :control, :execute, :types, :functions, :state, :state_lookup]
    before_action :check_support, only: [:state, :state_lookup, :functions]

    before_action :find_system, only: [:show, :update, :destroy, :remove,
                                       :start, :stop, :execute, :types, :functions]

    before_action :ensure_json, only: [:create, :update, :execute]

    @control_system : Model::ControlSystem?

    @core : ACAEngine::Core::Client? = nil

    # :nodoc:
    def core
      (@core ||= Core::Client.new(request_id: request.id)).as(Core::Client)
    end

    # ACAEngine Core service discovery
    @@core_discovery = HoundDog::Discovery.new(CORE_NAMESPACE)

    # Strong params for index method
    class IndexParams < Params
      attribute zone_id : String
      attribute module_id : String
    end

    # Query ControlSystem resources
    def index
      elastic = Model::ControlSystem.elastic
      query = Model::ControlSystem.elastic.query(params)
      args = IndexParams.new(params)

      # Filter systems via zone_id
      if (zone_id = args.zone_id)
        query.filter({
          "zones.keyword" => [zone_id],
        })
      end

      # Filter via module_id
      if (module_id = args.module_id)
        query.filter({
          "modules.keyword" => [module_id],
        })
      end

      query.sort(NAME_SORT_ASC)
      render json: elastic.search(query)
    end

    # Renders a control system
    def show
      control_system = @control_system.as(Model::ControlSystem)
      if params["complete"]?
        render json: with_fields(control_system, {
          :module_data => control_system.module_data,
          :zone_data   => control_system.zone_data,
        })
      else
        render json: control_system
      end
    end

    class UpdateParams < Params
      attribute version : Int32, presence: true
    end

    # Updates a control system
    def update
      body = request.body.as(IO)
      control_system = @control_system.as(Model::ControlSystem)

      args = UpdateParams.new(params).validate!
      version = args.version.as(Int32)

      head :conflict if version != control_system.version

      control_system.assign_attributes_from_json(body)
      control_system.version = version + 1

      save_and_respond(control_system)
    end

    def create
      save_and_respond Model::ControlSystem.from_json(request.body.as(IO))
    end

    def destroy
      @control_system.try &.destroy
      head :ok
    end

    class RemoveParams < Params
      attribute module_id : String, presence: true
    end

    # Removes the module from the system and deletes it if not used elsewhere
    #
    post("/:sys_id/remove", :remove) do
      control_system = @control_system.as(Model::ControlSystem)
      args = RemoveParams.new(params).validate!

      module_id = args.module_id.as(String)
      modules = control_system.modules || [] of String

      if modules.includes? module_id
        control_system.modules_will_change!
        control_system.modules.try &.delete(module_id)

        control_system.save! # with_cas: true

        # keep if any other ControlSystem is using the module
        keep = Model::ControlSystem.using_module(module_id).any? { |sys| sys.id != control_system.id }
        unless keep
          Model::Module.find(module_id).try &.destroy
        end
      end

      head :ok
    end

    # Module Functions
    ###########################################################################

    # Start modules
    #
    # FIXME: Optimise query
    post("/:sys_id/start", :start) do
      modules = @control_system.as(Model::ControlSystem).modules || [] of String
      Model::Module.find_all(modules).each do |mod|
        mod.update_fields(running: true)
      end

      head :ok
    end

    # Stop modules
    #
    # FIXME: Optimise query
    post("/:sys_id/stop", :stop) do
      modules = @control_system.as(Model::ControlSystem).modules || [] of String
      Model::Module.find_all(modules).each do |mod|
        mod.update_fields(running: false)
      end

      head :ok
    end

    # Driver Metadata, State and Status
    ###########################################################################

    # Runs a function in a system module
    #
    post("/:sys_id/:module_slug/:method", :execute) do
      sys_id, module_slug, method = params["sys_id"], params["module_slug"], params["method"]
      module_name, index = parse_module_slug(module_slug).as({String, Int32})
      args = Array(JSON::Any).from_json(request.body.as(IO))

      begin
        driver = Driver::Proxy::RemoteDriver.new(
          sys_id: sys_id,
          module_name: module_name,
          index: index
        )

        response = driver.exec(
          security: Systems.driver_clearance(user_token),
          function: method,
          args: args,
          request_id: logger.request_id,
        )
        render json: response
      rescue e : Driver::Proxy::RemoteDriver::Error
        message = e.error_code.to_s.gsub('_', ' ')
        case e.error_code
        when Driver::Proxy::RemoteDriver::ErrorCode::ModuleNotFound, Driver::Proxy::RemoteDriver::ErrorCode::SystemNotFound
          logger.tag(
            severity: Logger::Severity::INFO,
            message: message,
            error: e.message,
            sys_id: sys_id,
          )
          render status: :not_found, text: message
        else
          # when ParseError        # JSON parse failure
          # when BadRequest        # Pre-requisite does not exist (i.e no function)
          # when AccessDenied      # The current user does not have permissions
          # when RequestFailed     # The request was sent and error occured in core / the module
          # when UnknownCommand    # Not one of bind, unbind, exec, debug, ignore
          # when UnexpectedFailure # Some other transient failure like database unavailable
          logger.tag(
            severity: Logger::Severity::INFO,
            message: message,
            error: e.message,
            sys_id: sys_id,
          )
          render status: :internal_server_error, text: message
        end
      rescue e
        logger.tag(
          severity: Logger::Severity::ERROR,
          message: "core execute request failed",
          error: e.message,
          sys_id: sys_id,
          backtrace: e.inspect_with_backtrace
        )
        render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
      end
    end

    # Look-up a module types in a system, returning a count of each type
    #
    get("/:sys_id/types", :types) do
      control_system = @control_system.as(Model::ControlSystem)
      modules = Model::Module.find_all(control_system.id.as(String), index: :control_system_id)
      types = modules.each_with_object(Hash(String, Int32).new(0)) do |mod, count|
        count[mod.name.as(String)] += 1
      end

      render json: types
    end

    # Returns the state of an associated module
    #
    get("/:sys_id/:module_slug", :state) do
      sys_id, module_slug = params["sys_id"], params["module_slug"]
      module_name, index = parse_module_slug(module_slug).as({String, Int32})

      render json: module_state(sys_id, module_name, index)
    end

    # Returns the state lookup for a given key on a module
    #
    get("/:sys_id/:module_slug/:key", :state_lookup) do
      sys_id, key, module_slug = params["sys_id"], params["key"], params["module_slug"]
      module_name, index = parse_module_slug(module_slug).as({String, Int32})

      render json: module_state(sys_id, module_name, index, key)
    end

    # Lists functions available on the driver
    # Filters higher privilege functions.
    get("/:sys_id/functions/:module_slug", :functions) do
      sys_id, module_slug = params["sys_id"], params["module_slug"]
      module_name, index = parse_module_slug(module_slug).as({String, Int32})
      metadata = ACAEngine::Driver::Proxy::System.driver_metadata?(
        system_id: sys_id,
        module_name: module_name,
        index: index,
      )
      head :not_found unless metadata
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
      functions = metadata.functions.reject!(hidden_functions)

      # Transform function metadata
      response = functions.transform_values do |arguments|
        {
          arity:  arguments.size,
          params: arguments,
        }
      end

      render json: response
    end

    def module_state(sys_id : String, module_name : String, index : Int32, key : String? = nil)
      # Look up module's id for module on system
      module_id = ACAEngine::Driver::Proxy::System.module_id?(
        system_id: sys_id,
        module_name: module_name,
        index: index
      )

      if module_id
        # Grab drive(r state proxy
        storage = ACAEngine::Driver::Storage.new(module_id)
        # Perform lookup, otherwise dump state
        key ? storage[key] : storage.to_h
      end
    end

    def parse_module_slug(module_slug : String) : {String, Int32}?
      if module_slug.count('_') == 1
        module_name, index = module_slug.split('_')
        ({module_name, index.to_i})
      else
        head :bad_request
      end
    end

    # Websockets
    ###########################################################################

    ws("/control", :control) do |ws|
      log = logger
      Systems.session_manager.create_session(
        ws: ws,
        request_id: log.request_id || "",
        user: user_token,
        logger: logger,
      )
    end

    # Helpers
    ###########################################################################

    def self.driver_clearance(user : Model::User | Model::UserJWT)
      if user.is_admin?
        Driver::Proxy::RemoteDriver::Clearance::Admin
      elsif user.is_support?
        Driver::Proxy::RemoteDriver::Clearance::Support
      else
        Driver::Proxy::RemoteDriver::Clearance::User
      end
    end

    def self.locate_module(module_id : String) : URI
      # Use consistent hashing to determine the location of the module
      node = @@core_discovery.find!(module_id)
      URI.new(host: node[:ip], port: node[:port])
    end

    # Determine URI for a system module
    def self.locate_module?(sys_id : String, module_name : String, index : Int32) : URI?
      module_id = ACAEngine::Driver::Proxy::System.module_id?(sys_id, module_name, index)
      module_id.try &->self.locate_module(String)
    end

    # Create a core client for given module id
    def self.core_for(module_id : String, request_id : String? = nil) : Core::Client
      Core::Client.new(uri: self.locate_module(module_id), request_id: request_id)
    end

    # Lazy initializer for session_manager
    def self.session_manager
      (@@session_manager ||= Session::Manager.new(@@core_discovery)).as(Session::Manager)
    end

    def self.driver_security_clearance(user : Model::User | Model::UserJWT)
      if user.is_admin?
        Driver::Proxy::RemoteDriver::Clearance::Admin
      elsif user.is_support?
        Driver::Proxy::RemoteDriver::Clearance::Support
      else
        Driver::Proxy::RemoteDriver::Clearance::User
      end
    end

    @@session_manager : Session::Manager? = nil

    def find_system
      # Find will raise a 404 (not found) if there is an error
      @control_system = Model::ControlSystem.find!(params["sys_id"]?)
    end
  end
end
