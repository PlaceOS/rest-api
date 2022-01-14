require "hound-dog"

require "placeos-core-client"
require "placeos-driver/proxy/system"

require "./application"
require "./modules"
require "./settings"
require "../websocket"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

# TODO: Remove after this PR is merged https://github.com/crystal-lang/crystal/pull/10922
module Enumerable(T)
  def tally_by(& : T -> U) : Hash(U, Int32) forall U
    each_with_object(Hash(U, Int32).new) do |item, hash|
      count = hash[value = yield item]?
      hash[value] = count ? count + 1 : 1
    end
  end
end

module PlaceOS::Api
  class Systems < Application
    include Utils::CoreHelper
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController

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
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt, :start, :stop]

    before_action :can_read_control, only: [:types, :functions, :state, :state_lookup]
    before_action :can_write_control, only: [:control, :execute]

    before_action :check_admin, except: [:index, :show, :find_by_email, :control, :execute,
                                         :types, :functions, :state, :state_lookup]

    before_action :check_support, only: [:state, :state_lookup, :functions]

    # Callbacks
    ###############################################################################################

    before_action :current_control_system, only: [:show, :update, :destroy, :remove,
                                                  :start, :stop, :execute,
                                                  :types, :functions, :metadata]

    before_action :ensure_json, only: [:create, :update, :update_alt, :execute]
    before_action :body, only: [:create, :execute, :update, :update_alt]

    getter current_control_system : Model::ControlSystem { find_system }

    # Websocket API session manager
    class_getter session_manager : WebSocket::Manager { WebSocket::Manager.new(core_discovery) }

    # Strong params for index method
    class IndexParams < Params
      attribute bookable : Bool?
      attribute capacity : Int32?
      attribute email : String?
      attribute features : String?
      attribute module_id : String?
      attribute trigger_id : String?
      attribute zone_id : String?
    end

    # Query ControlSystem resources
    @[OpenAPI(
      <<-YAML
        summary: Query ControlSystem resources
        parameters:
          #{Schema.qp "bookable", "filter by bookable", type: "boolean"}
          #{Schema.qp "capacity", "filter by capacity", type: "integer"}
          #{Schema.qp "email", "filter by email", type: "string"}
          #{Schema.qp "features", "filter by features", type: "string"}
          #{Schema.qp "module_id", "filter by module_id", type: "string"}
          #{Schema.qp "trigger_id", "filter by trigger_id", type: "string"}
          #{Schema.qp "zone_id", "filter by zone_id", type: "string"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array ControlSystem}
      YAML
    )]
    def index
      elastic = Model::ControlSystem.elastic
      query = Model::ControlSystem.elastic.query(params)
      args = IndexParams.new(params)

      # Filter systems by zone_id
      if zone_id = args.zone_id
        query.must({
          "zones" => [zone_id],
        })
      end

      # Filter by module_id
      if module_id = args.module_id
        query.must({
          "modules" => [module_id],
        })
      end

      # Filter by trigger_id
      if trigger_id = args.trigger_id
        query.has_child(Model::TriggerInstance)
        query.must({
          "trigger_id" => [trigger_id],
        })
      end

      # Filter by features
      if features = args.features
        features = features.split(',').uniq.reject! &.empty?
        query.must({
          "features" => features,
        })
      end

      # filter by capacity
      if capacity = args.capacity
        query.range({
          "capacity" => {
            :gte => capacity,
          },
        })
      end

      # filter by bookable
      unless (bookable = args.bookable).nil?
        query.must({
          "bookable" => [bookable],
        })
      end

      # filter by emails
      if email = args.email
        emails = email.split(',').uniq.reject! &.empty?
        query.should({
          "email" => emails,
        })
      end

      query.search_field "name"
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    # Finds all the systems with the specified email address
    get("/with_emails", :find_by_email, annotations: @[OpenAPI(<<-YAML
    summary: Finds all the systems with the specified email address
    parameters:
          #{Schema.qp "in", "emails seperated by ,", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref_array ControlSystem}
  YAML
    )]) do
      emails = params["in"].split(',').map(&.strip).reject(&.empty?).uniq!
      systems = Model::ControlSystem.find_all(emails, index: :email).to_a
      set_collection_headers(systems.size, Model::ControlSystem.table_name)
      render json: systems
    end

    # Renders a control system
    @[OpenAPI(
      <<-YAML
        summary: Renders a control system
        parameters:
          #{Schema.qp "complete", "render with all fields associated", type: "boolean"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref ControlSystem}
      YAML
    )]
    def show
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        head :forbidden unless user_token.user.roles.includes?(current_control_system.id)
        render json: current_control_system
      end

      complete = params["complete"]? == "true"
      render json: !complete ? current_control_system : with_fields(current_control_system, {
        :module_data => current_control_system.module_data,
        :zone_data   => current_control_system.zone_data,
      })
    end

    class UpdateParams < Params
      attribute version : Int32, presence: true
    end

    # Updates a control system
    @[OpenAPI(
      <<-YAML
        summary: Update a control system
        parameters:
          #{Schema.qp "version", "can only edit current control system", type: "string"}
        requestBody:
          required: true
          content:
            #{Schema.ref ControlSystem}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref ControlSystem}
      YAML
    )]
    def update
      args = UpdateParams.new(params)

      unless args.valid?
        return render_error(HTTP::Status::PRECONDITION_FAILED, "Missing System version parameter")
      end

      version = args.version

      if version != current_control_system.version
        return render_error(HTTP::Status::CONFLICT, "Attempting to edit an old System version")
      end

      current_control_system.assign_attributes_from_json(self.body)
      current_control_system.version = version + 1

      save_and_respond(current_control_system)
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:sys_id", :update_alt, annotations: @[OpenAPI(<<-YAML
        summary: Update a control system
        parameters:
          #{Schema.qp "version", "can only edit current control system", type: "string"}
        requestBody:
          required: true
          content:
            #{Schema.ref ControlSystem}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref ControlSystem}
      YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a control system
        requestBody:
          required: true
          content:
            #{Schema.ref ControlSystem}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref ControlSystem}
      YAML
    )]
    def create
      save_and_respond Model::ControlSystem.from_json(self.body)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete the current control system
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_control_system.destroy
      head :ok
    end

    # Return all zones for this system
    #
    get("/:sys_id/zones", :sys_zones, annotations: @[OpenAPI(<<-YAML
    summary: Return all zones for this system
    parameters:
      #{Schema.qp "sys_id", "Can only get info on systems the user has access to", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref_array Zone}
      403:
        description: Forbidden
    YAML
    )]) do
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        head :forbidden unless user_token.user.roles.includes?(params["sys_id"])
      end

      # Save the DB hit if there are no zones on the system
      documents = if current_control_system.zones.empty?
                    [] of Model::Zone
                  else
                    Model::Zone.find_all(current_control_system.zones).to_a
                  end

      set_collection_headers(documents.size, Model::Zone.table_name)

      render json: documents
    end

    # Return metadata for the system
    #
    get("/:sys_id/metadata", :metadata, annotations: @[OpenAPI(<<-YAML
    summary: Return metadata for the system
    parameters:
      #{Schema.qp "name", "", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Open_Metadata}
    YAML
    )]) do
      parent_id = current_control_system.id.not_nil!
      name = params["name"]?.presence
      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    # Receive the collated settings for a system
    #
    get("/:sys_id/settings", :settings, annotations: @[OpenAPI(<<-YAML
    summary: Receive the collated settings for a system
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Open_Settings}
    YAML
    )]) do
      render json: Api::Settings.collated_settings(current_user, current_control_system)
    end

    # Adds the module from the system if it doesn't already exist
    #
    put("/:sys_id/module/:module_id", :add_module, annotations: @[OpenAPI(<<-YAML
    summary: Adds the module from the system if it doesn't already exist
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref ControlSystem}
      500:
        description: Internal Server Error
      404:
        description: Not Found
    YAML
    )]) do
      control_system_id = params["sys_id"]
      module_id = params["module_id"]

      head :not_found unless Model::Module.exists?(module_id)

      module_present = current_control_system.modules.includes?(module_id) || Model::ControlSystem.add_module(control_system_id, module_id)

      unless module_present
        render text: "Failed to add ControlSystem Module", status: :internal_server_error
      end

      # Return the latest version of the control system
      render json: Model::ControlSystem.find!(control_system_id, runopts: {"read_mode" => "majority"})
    end

    # Removes the module from the system and deletes it if not used elsewhere
    #
    delete("/:sys_id/module/:module_id", :remove_module, annotations: @[OpenAPI(<<-YAML
    summary: Removes the module from the system and deletes it if not used elsewhere
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref ControlSystem}
    YAML
    )]) do
      module_id = params["module_id"]

      if current_control_system.modules.includes?(module_id)
        current_control_system.remove_module(module_id)
        current_control_system.save!
      end

      render json: current_control_system
    end

    # Module Functions
    ###########################################################################

    # Start modules
    #
    post("/:sys_id/start", :start, annotations: @[OpenAPI(<<-YAML
    summary: Start modules
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
      Systems.module_running_state(running: true, control_system: current_control_system)

      head :ok
    end

    # Stop modules
    #
    post("/:sys_id/stop", :stop, annotations: @[OpenAPI(<<-YAML
    summary: Stop modules
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
      Systems.module_running_state(running: false, control_system: current_control_system)

      head :ok
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
    #
    post("/:sys_id/:module_slug/:method", :execute, annotations: @[OpenAPI(<<-YAML
    summary: Runs a function in a system module
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
      500:
        description: Internal Server Error
    YAML
    )]) do
      sys_id, module_slug, method = params["sys_id"], params["module_slug"], params["method"]
      module_name, index = RemoteDriver.get_parts(module_slug)
      args = Array(JSON::Any).from_json(self.body)

      remote_driver = RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        discovery: self.class.core_discovery
      )

      ret_val = remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )
      response.headers["Content-Type"] = "application/json"
      render text: ret_val
    rescue e : RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      Log.error(exception: e) { {message: "core execute request failed", sys_id: sys_id, module_name: module_name} }
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Look-up a module types in a system, returning a count of each type
    #
    get("/:sys_id/types", :types, annotations: @[OpenAPI(<<-YAML
    summary: Look-up a module types in a system, returning a count of each type
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
      types = Model::Module
        .in_control_system(current_control_system.id.as(String))
        .tally_by(&.resolved_name)
      render json: types
    end

    # Returns the state of an associated module
    #
    get("/:sys_id/:module_slug", :state, annotations: @[OpenAPI(<<-YAML
    summary: Returns the state of an associated module
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
      sys_id, module_slug = params["sys_id"], params["module_slug"]
      module_name, index = RemoteDriver.get_parts(module_slug)

      render json: self.class.module_state(sys_id, module_name, index)
    end

    # Returns the state lookup for a given key on a module
    #
    get("/:sys_id/:module_slug/:key", :state_lookup, annotations: @[OpenAPI(<<-YAML
    summary: Returns the state lookup for a given key on a module
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
      sys_id, key, module_slug = params["sys_id"], params["key"], params["module_slug"]
      module_name, index = RemoteDriver.get_parts(module_slug)

      render json: self.class.module_state(sys_id, module_name, index, key)
    end

    # Lists functions available on the driver
    # Filters higher privilege functions.
    get("/:sys_id/functions/:module_slug", :functions, annotations: @[OpenAPI(<<-YAML
    summary: Lists functions available on the driver, Filters higher privilege functions
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
      404:
        description: Not Found
    YAML
    )]) do
      sys_id, module_slug = params["sys_id"], params["module_slug"]
      module_name, index = RemoteDriver.get_parts(module_slug)
      metadata = ::PlaceOS::Driver::Proxy::System.driver_metadata?(
        system_id: sys_id,
        module_name: module_name,
        index: index,
      )

      unless metadata
        Log.debug { "metadata not found for #{module_slug} on #{sys_id}" }
        head :not_found
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
      response = functions.transform_values do |arguments|
        {
          arity:  arguments.size,
          params: arguments,
          order:  arguments.keys,
        }
      end

      render json: response
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

    ws("/control", :control, annotations: @[OpenAPI(<<-YAML
    summary: Websocket API
    responses:
      200:
        description: OK
    YAML
    )]) do |ws|
      Log.trace { "WebSocket API request" }
      fixed_device = params["fixed_device"]?.try(&.downcase) == "true"
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

    protected def find_system
      id = params["sys_id"]
      Log.context.set(control_system_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::ControlSystem.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
