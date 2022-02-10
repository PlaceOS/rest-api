require "promise"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edges < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/edges/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show, :edge]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_edge, only: [:destroy, :drivers, :show, :update, :update_alt, :token]
    before_action :body, only: [:create, :update, :update_alt]

    skip_action :authorize!, only: [:edge]
    skip_action :set_user_id, only: [:edge]

    # Params
    ###############################################################################################

    getter token : String? do
      params["token"]?.presence
    end

    ###############################################################################################

    getter current_edge : Model::Edge { find_edge }

    class_getter connection_manager : ConnectionManager { ConnectionManager.new(core_discovery) }

    # Validate the present of the id and check the secret before routing to core
    ws("/control", :edge, annotations: @[OpenAPI(<<-YAML
    summary: Validate the present of the id and check the secret before routing to core
    parameters:
          #{Schema.qp "token", "authenticated token", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
      401:
        description: Unauthorized
    YAML
    )]) do |socket|
      authentication_token = required_param(token)

      return render_error(HTTP::Status::BAD_REQUEST, "Missing 'token' param") if token.nil? || token.presence.nil?

      edge_id = Model::Edge.validate_token?(token)

      head status: :unauthorized if edge_id.nil?

      edge_id = Model::Edge.validate_token?(authentication_token)

      if edge_id.nil?
        head status: :unauthorized
      else
        Log.info { {edge_id: edge_id, message: "new edge connection"} }
        Edges.connection_manager.add_edge(edge_id, socket)
      end
    end

    get("/:id/token", :token, annotations: @[OpenAPI(<<-YAML
    summary: Get the token associated with the given id
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
      403:
        description: Forbidden
    YAML
    )]) do
      head :forbidden unless is_admin?
      render json: {token: current_edge.token(current_user)}
    end

    @[OpenAPI(
      <<-YAML
        summary: get all edges
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Model::Edge}
      YAML
    )]
    def index
      elastic = Model::Edge.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current edge
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::Edge}
      YAML
    )]
    def show
      render json: current_edge
    end

    @[OpenAPI(
      <<-YAML
        summary: Update an edge
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Edge}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::Edge}
      YAML
    )]
    def update
      current_edge.assign_attributes_from_json(self.body)
      save_and_respond current_edge
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
    summary: Update an edge
    requestBody:
      required: true
      content:
        #{Schema.ref Model::Edge}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Model::Edge}
    YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create an edge
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Edge}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Model::Edge}
      YAML
    )]
    def create
      save_and_respond(Model::Edge.from_json(self.body))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete an edge
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_edge.destroy
      head :ok
    end

    # Helpers
    ###########################################################################

    protected def find_edge
      id = params["id"]
      Log.context.set(edge_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Edge.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end

require "./edges/connection_manager"
