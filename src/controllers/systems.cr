require "hound-dog"

require "engine-core/client"
require "engine-driver/proxy/system"

require "./application"
require "../session"

module ACAEngine::Api
  class Systems < Application
    base "/api/engine/v2/systems/"

    id_param :sys_id

    before_action :find_system, only: [:show, :update, :destroy, :remove,
                                       :start, :stop, :execute, :types, :functions]

    before_action :ensure_json, only: [:create, :update]

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
      if params["complete"]?
        render json: with_fields(@control_system, {
          :module_data => @control_system.try &.module_data,
          :zone_data   => @control_system.try &.zone_data,
        })
      else
        render json: @control_system
      end
    end

    class UpdateParams < Params
      attribute version : Int32, presence: true
    end

    # Updates a control system
    def update
      body = request.body.not_nil!
      control_system = @control_system.as(Model::ControlSystem)

      args = UpdateParams.new(params).validate!
      version = args.version.as(Int32)

      head :conflict if version != control_system.version

      control_system.assign_attributes_from_json(body)
      control_system.version = version + 1

      save_and_respond(control_system)
    end

    def create
      body = request.body.not_nil!
      save_and_respond Model::ControlSystem.from_json(body)
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

    class ExecuteParams < Params
      attribute sys_id : String

      attribute module_name : String
      attribute index : Int32 = 1

      attribute method : String
      attribute args : Array(JSON::Any)

      validates :method, presence: true
      validates :module_name, presence: true
    end

    # Runs a function in a system module (async request)
    #
    post("/:sys_id/execute", :execute) do
      args = ExecuteParams.new(params).validate!

      begin
        value = nil
        url = Systems.locate_module?(
          sys_id: args.sys_id.as(String),
          module_name: args.module_name.as(String),
          index: args.index.as(Int32),
        )
        head :not_found unless url
      rescue e
        logger.error("core execute request failed: params=#{args.attributes} message=#{e.message} backtrace=#{e.inspect_with_backtrace}")
        render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
      end

      render json: value
    end

    # Create a core client for given module id
    def self.core_for(module_id : String, request_id : String? = nil) : Core::Client
      Core::Client.new(uri: self.locate_module(module_id), request_id: request_id)
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

    # class CountParams < Params
    #   attribute module_name : String, presence: true
    # end
    #

    # # Returns the count of a module type in a system
    # #
    # get("/:sys_id/count", :count) do
    #   sys = @control_system.as(Model::ControlSystem)
    #   args = CountParams.new(params).validate!
    #   render json: {count: sys.count(args.module_name)}
    # end

    # # Looksup a module types in a system, returning a count of each type
    # #
    # get("/:sys_id/types", :types) do
    #   control_system = @control_system.as(Model::ControlSystem)
    #   render json: control_system.modules.each_with_object({} of String => Int32) do |mod, counts|
    #     counts[mod] = control_system.count(mod)
    #   end
    # end

    class StateParams < Params
      attribute lookup : Symbol

      attribute sys_id : String
      attribute module_name : String
      attribute index : Int32 = 1

      validates :module_name, presence: true
      validates :sys_id, presence: true
    end

    # Returns the state of an associated module
    #
    get("/:sys_id/state", :state) do
      # Status defined as a system module
      args = StateParams.new(params).validate!

      # Look up module's id for module on system
      module_id = ACAEngine::Driver::Proxy::System.module_id?(
        system_id: args.sys_id.as(String),
        module_name: args.module_name.as(String),
        index: args.index.as(Int32)
      )

      if module_id
        # Grab driver state proxy
        storage = ACAEngine::Driver::Storage.new(module_id)

        # Perform lookup, otherwise dump state
        render json: ((lookup = args.lookup) ? storage[lookup] : storage.to_h)
      else
        head :not_found
      end
    end

    class FunctionsParams < Params
      attribute sys_id : String
      attribute module_name : String
      attribute index : Int32 = 1

      validates :module_name, presence: true
    end

    # Lists functions available on the driver
    # Filters higher privilege functions.
    get("/:sys_id/functions", :functions) do
      args = FunctionsParams.new(params).validate!

      metadata = ACAEngine::Driver::Proxy::System.driver_metadata?(
        system_id: args.sys_id.as(String),
        module_name: args.module_name.as(String),
        index: args.index.as(Int32),
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

    # Websockets
    ###########################################################################

    ws("/bind", :bind) do |ws|
      log = logger
      Systems.session_manager.create_session(
        ws: ws,
        request_id: log.request_id || "",
        user: user_token,
      )
    end

    # Lazy initializer for session_manager
    def self.session_manager
      (@@session_manager ||= Session::Manager.new(@@core_discovery, ActionController::Base.settings.logger)).as(Session::Manager)
    end

    @@session_manager : Session::Manager? = nil

    def find_system
      # Find will raise a 404 (not found) if there is an error
      @control_system = Model::ControlSystem.find!(params["sys_id"]?)
    end
  end
end
