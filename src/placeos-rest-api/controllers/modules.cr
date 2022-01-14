require "pinger"
require "placeos-driver/storage"

require "./application"
require "./drivers"
require "./settings"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Modules < Application
    include Utils::CoreHelper
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController

    base "/api/engine/v2/modules/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :state, :show, :ping]
    before_action :check_support, only: [:index, :state, :show, :ping]

    # Callbacks
    ###############################################################################################

    before_action :ensure_json, only: [:create, :update, :update_alt, :execute]
    before_action :current_module, only: [:show, :update, :update_alt, :destroy, :ping, :state]
    before_action :body, only: [:create, :execute, :update, :update_alt]

    # Params
    ###############################################################################################

    getter module_id : String do
      params["id"]
    end

    getter method : String do
      params["method"]
    end

    getter key : String do
      params["key"]
    end

    ###############################################################################################

    getter current_module : Model::Module { find_module }

    private class IndexParams < Params
      attribute as_of : Int32?
      attribute control_system_id : String?
      attribute connected : Bool?
      attribute driver_id : String?
      attribute no_logic : Bool = false
      attribute running : Bool?
    end

    DRIVER_ATTRIBUTES = %w(name description)

    @[OpenAPI(
      <<-YAML
        summary: Get modules
        parameters:
          #{Schema.qp "as_of", "filter by as_of", type: "integer"}
          #{Schema.qp "control_system_id", "query the database directly if present", type: "string"}
          #{Schema.qp "connected", "filter by connected", type: "boolean"}
          #{Schema.qp "driver_id", "filter by driver_id", type: "string"}
          #{Schema.qp "no_logic", "filter by no_logic", type: "boolean"}
          #{Schema.qp "running", "filter by running", type: "boolean"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Module}
      YAML
    )]
    def index
      args = IndexParams.new(params)

      # if a system id is present we query the database directly
      if (sys_id = args.control_system_id)
        cs = Model::ControlSystem.find!(sys_id)
        # Include subset of association data with results
        results = Model::Module.find_all(cs.modules).compact_map do |mod|
          next if (driver = mod.driver).nil?

          # Most human readable module data is contained in driver
          driver_field = restrict_attributes(
            driver,
            only: DRIVER_ATTRIBUTES,
          )

          with_fields(mod, {
            :driver   => driver_field,
            :compiled => Api::Modules.driver_compiled?(mod, request_id),
          })
        end.to_a

        set_collection_headers(results.size, Model::Module.table_name)

        render json: results
      else # we use Elasticsearch
        elastic = Model::Module.elastic
        query = elastic.query(params)

        if (driver_id = args.driver_id)
          query.filter({"driver_id" => [driver_id]})
        end

        unless (connected = args.connected).nil?
          query.filter({
            "ignore_connected" => [false],
            "connected"        => [connected],
          })
        end

        unless (running = args.running).nil?
          query.should({"running" => [running]})
        end

        if (as_of = args.as_of)
          query.range({
            "updated_at" => {
              :lte => as_of,
            },
          })
        end

        if args.no_logic
          query.must_not({"role" => [Model::Driver::Role::Logic.to_i]})
        end

        # NOTE: parent queries appear to fail as of `placeos-1.2109.1`
        # query.has_parent(parent: Model::Driver, parent_index: Model::Driver.table_name)

        search_results = paginate_results(elastic, query)

        # Include subset of association data with results
        includes = search_results.compact_map do |d|
          sys = d.control_system
          driver = d.driver
          next unless driver

          # Most human readable module data is contained in driver
          driver_field = restrict_attributes(
            driver,
            only: DRIVER_ATTRIBUTES,
          )

          # Include control system on Logic modules so it is possible
          # to display the inherited settings
          sys_field = if sys
                        restrict_attributes(
                          sys,
                          only: [
                            "name",
                          ],
                          fields: {
                            :zone_data => sys.zone_data,
                          }
                        )
                      else
                        nil
                      end

          with_fields(d, {
            :control_system => sys_field,
            :driver         => driver_field,
          }.compact)
        end

        render json: includes
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Get module
        parameters:
          #{Schema.qp "complete", "return module with all possible fields", type: "boolean"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Module}
      YAML
    )]
    def show
      complete = boolean_param("complete")

      response = !complete ? current_module : with_fields(current_module, {
        :driver => restrict_attributes(current_module.driver, only: DRIVER_ATTRIBUTES),
      })

      render json: response
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a module
        requestBody:
          required: true
          content:
            #{Schema.ref Module}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Module}
      YAML
    )]
    def update
      current_module.assign_attributes_from_json(self.body)

      save_and_respond(current_module) do |mod|
        driver = mod.driver
        !driver ? mod : with_fields(mod, {
          :driver => restrict_attributes(driver, only: DRIVER_ATTRIBUTES),
        })
      end
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
    summary: Update a module
    requestBody:
      required: true
      content:
        #{Schema.ref Module}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Module}
    YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a module
        requestBody:
          required: true
          content:
            #{Schema.ref Module}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Module}
      YAML
    )]
    def create
      save_and_respond(Model::Module.from_json(self.body))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a module
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_module.destroy
      head :ok
    end

    # Receive the collated settings for a module
    #
    get("/:id/settings", :settings, annotations: @[OpenAPI(<<-YAML
      summary: Receive the collated settings for a module
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
          content:
                #{Schema.ref Open_Settings}
      YAML
    )]) do
      render json: Api::Settings.collated_settings(current_user, current_module)
    end

    # Starts a module
    post("/:id/start", :start, annotations: @[OpenAPI(<<-YAML
      summary: Starts a module
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
        500:
          description: Internal Server Error
      YAML
    )]) do
      head :ok if current_module.running == true

      current_module.update_fields(running: true)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "start", module_id: current_module.id, event: "failed"} }
        head :internal_server_error
      else
        head :ok
      end
    end

    # Stops a module
    post("/:id/stop", :stop, annotations: @[OpenAPI(<<-YAML
      summary: Stops a module
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
        500:
          description: Internal Server Error
      YAML
    )]) do
      head :ok unless current_module.running

      current_module.update_fields(running: false)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "stop", module_id: current_module.id, event: "failed"} }
        head :internal_server_error
      else
        head :ok
      end
    end

    # Executes a command on a module
    post("/:id/exec/:method", :execute, annotations: @[OpenAPI(<<-YAML
      summary: Executes a command on a module
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
        500:
          description: Internal Server Error
      YAML
    )]) do
      id, method = params["id"], params["method"]
      sys_id = current_module.control_system_id || ""
      args = Array(JSON::Any).from_json(self.body)

      result = Driver::Proxy::RemoteDriver.new(
        module_id: module_id,
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

      response.content_type = "application/json"
      render text: result
    rescue e : Driver::Proxy::RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        sys_id:      sys_id,
        module_id:   module_id,
        module_name: current_module.name,
        method:      method,
      } }

      if Api.production?
        render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message)
      else
        render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message, backtrace: e.backtrace?)
      end
    end

    # Dumps the complete status state of the module
    get("/:id/state", :state, annotations: @[OpenAPI(<<-YAML
      summary: Dumps the complete status state of the module
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      render json: self.class.module_state(current_module)
    end

    # Returns the value of the requested status variable
    get("/:id/state/:key", :state_lookup, annotations: @[OpenAPI(<<-YAML
      summary: Returns the value of the requested status variable
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      render json: self.class.module_state(current_module, key)
    end

    post("/:id/ping", :ping, annotations: @[OpenAPI(<<-YAML
      summary: Pings module at provided ID
      security:
      - bearerAuth: []
      responses:
        406:
          description: Not Acceptable
        200:
          description: OK
      YAML
    )]) do
      if current_module.role.logic?
        Log.debug { {controller: "Modules", action: "ping", module_id: current_module.id, role: current_module.role.to_s} }
        head :not_acceptable
      else
        pinger = Pinger.new(current_module.hostname.as(String), count: 3)
        pinger.ping
        render json: {
          host:      pinger.ip.to_s,
          pingable:  pinger.pingable,
          warning:   pinger.warning,
          exception: pinger.exception,
        }
      end
    end

    post("/:id/load", :load, annotations: @[OpenAPI(<<-YAML
      summary: Loads system at provided ID
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      module_id = params["id"]
      render json: Api::Systems.core_for(module_id, request_id, &.load(module_id))
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

    # Helpers
    ###############################################################################################

    protected def find_module
      Log.context.set(module_id: module_id)
      # Find will raise a 404 (not found) if there is an error
      Model::Module.find!(module_id, runopts: {"read_mode" => "majority"})
    end
  end
end
