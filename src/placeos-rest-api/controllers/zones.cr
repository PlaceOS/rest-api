require "promise"
require "action-controller"
require "openapi-generator"
require "openapi-generator/providers/action-controller"
require "openapi-generator/helpers/action-controller"
require "placeos-log-backend"

require "./application"

module PlaceOS::Api
  class Zones < Application
    include Utils::CoreHelper
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController

    base "/api/engine/v2/zones/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, except: [:index]

    # Callbacks
    ###############################################################################################

    before_action :current_zone, only: [:show, :update, :update_alt, :destroy, :metadata]
    before_action :body, only: [:create, :update, :update_alt, :zone_execute]

    ###############################################################################################

    getter current_zone : Model::Zone { find_zone }

    @[OpenAPI(
      <<-YAML
        summary: get all zones
        parameters:
          #{Schema.qp "limit", "The maximum numbers of zones to return", type: "integer"}
          #{Schema.qp "parent", "Limit results to the children of this parent zone", type: "string"}
          #{Schema.qp "tags", "return zones with the specified tags", type: "string"}
          #{Schema.qp "q", "Search query term", type: "string"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Zone}
      YAML
    )]
    def index
      elastic = Model::Zone.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      # Limit results to the children of this parent
      if params.has_key? "parent"
        query.must({
          "parent_id" => [params["parent"]],
        })
      end

      if params.has_key? "tags"
        # list of unique tags
        tags = params["tags"].gsub(/[^0-9a-z ]/i, "").split(',').reject(&.empty?).uniq!

        head :bad_request if tags.empty?

        query.must({
          "tags" => tags,
        })
      else
        head :forbidden unless is_support? || is_admin?

        query.search_field "name"
      end

      render json: paginate_results(elastic, query)
    end

    # BREAKING CHANGE: param key `data` used to attempt to retrieve a setting from the zone
    @[OpenAPI(
      <<-YAML
        summary: get a zone
        parameters:
          #{Schema.qp name: "complete", description: "Include trigger data in response", required: false, type: "string"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Zone}
      YAML
    )]
    def show
      if params.has_key? "complete"
        # Include trigger data in response
        render json: with_fields(current_zone, {
          :trigger_data => current_zone.trigger_data,
        })
      else
        render json: current_zone
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a zone
        requestBody:
          required: true
          content:
            #{Schema.ref Zone}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Zone}
      YAML
    )]
    def update
      current_zone.assign_attributes_from_json(self.body)
      save_and_respond current_zone
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
    summary: Update a zone
    requestBody:
      required: true
      content:
        #{Schema.ref Zone}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Zone}
  YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a zone
        requestBody:
          required: true
          content:
            #{Schema.ref Zone}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Zone}
      YAML
    )]
    def create
      save_and_respond Model::Zone.from_json(self.body)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a zone
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_zone.destroy
      head :ok
    end

    get("/:id/metadata", :metadata, annotations: @[OpenAPI(<<-YAML
    summary: Get the metadata of a zone
    parameters:
      #{Schema.qp "name", "The name of the metadata", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Open_Metadata}
    YAML
    )]) do
      parent_id = current_zone.id.not_nil!
      name = params["name"]?.presence
      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    private enum ExecStatus
      Success
      Failure
      Missing
    end

    # Return triggers attached to current zone
    #
    get("/:id/triggers", :trigger_instances, annotations: @[OpenAPI(<<-YAML
      summary: get the triggers attached to current zone
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
          content:
            #{Schema.ref_array Trigger}
      YAML
    )]) do
      triggers = current_zone.trigger_data
      set_collection_headers(triggers.size, Model::Trigger.table_name)
      render json: triggers
    end

    record(
      ZoneExecResponse,
      success : Array(String) = [] of String,
      failure : Array(String) = [] of String,
      module_missing : Array(String) = [] of String
    ) { include JSON::Serializable }

    post("/:id/exec/:module_slug/:method", :zone_execute, annotations: @[OpenAPI(<<-YAML
        summary: Execute a method on a module across all systems in a Zone
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
        YAML
    )]) do
      zone_id, module_slug, method = params["id"], params["module_slug"], params["method"]
      args = Array(JSON::Any).from_json(self.body)

      # Crystal BUG: total function, it should destructure with correct types
      module_parts = Driver::Proxy::RemoteDriver.get_parts(module_slug)
      module_name, index = module_parts

      results = Promise.map(current_zone.systems) do |system|
        system_id = system.id.as(String)
        begin
          remote_driver = Driver::Proxy::RemoteDriver.new(
            sys_id: system_id,
            module_name: module_name.as(String),
            index: index.as(Int32)
          )

          output = remote_driver.exec(
            security: driver_clearance(user_token),
            function: method.as(String), # BUG: This should not require casting
            args: args,
            request_id: request_id,
          )

          Log.debug { {message: "module exec success", system_id: system_id, module_name: module_name, index: index, method: method, output: output} }

          {system_id, ExecStatus::Success}
        rescue e : Driver::Proxy::RemoteDriver::Error
          handle_execute_error(e, respond: false)
          status = e.error_code.module_not_found? ? ExecStatus::Missing : ExecStatus::Failure
          {system_id, status}
        end
      end.get.not_nil!.to_a.compact

      response_object = results.each_with_object(ZoneExecResponse.new) do |(id, status), obj|
        case status
        in ExecStatus::Success then obj.success
        in ExecStatus::Failure then obj.failure
        in ExecStatus::Missing then obj.module_missing
        end << id
      end

      render json: response_object
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        zone_id:     zone_id,
        module_name: module_name,
        index:       index,
        method:      method,
      } }
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Helpers
    ###########################################################################

    protected def find_zone
      id = params["id"]
      Log.context.set(zone_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Zone.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
