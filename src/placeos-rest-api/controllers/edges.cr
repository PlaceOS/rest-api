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

    generate_scope_check(Model::Edge::CONTROL_SCOPE)

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show, :edge_control]
    before_action :check_support, only: [:index, :show]

    before_action :can_write_edge_control, only: [:edge_control]

    # Callbacks
    ###############################################################################################

    before_action :current_edge, only: [:destroy, :drivers, :show, :update, :update_alt, :token]
    before_action :body, only: [:create, :update, :update_alt]

    skip_action :set_user_id, only: [:edge_control]

    ###############################################################################################

    getter current_edge : Model::Edge { find_edge }

    class_getter connection_manager : ConnectionManager { ConnectionManager.new(core_discovery) }

    # Validate the present of the id and check the secret before routing to core
    ws("/control", :edge_control) do |socket|
      edge_id = Model::Edge.jwt_edge_id?(user_token)

      if edge_id.nil? || !Model::Edge.exists?(edge_id)
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
    YAML
    )]) do
      head :forbidden unless is_admin?
      render json: {token: current_edge.x_api_key}
    end

    @[OpenAPI(
      <<-YAML
        summary: get all edges
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      elastic = Model::Edge.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query), type: Array(Model::Edge)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current edge
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      render json: current_edge, type: Model::Edge
    end

    @[OpenAPI(
      <<-YAML
        summary: Update an edge
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      current_edge.assign_attributes_from_json(body_raw Model::Edge)
      save_and_respond current_edge
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a edge
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      create_body = body_as Model::Edge::CreateBody, constructor: :from_json
      user = Model::User.find!(create_body.user_id)
      save_and_respond(Model::Edge.for_user(
        user: user,
        name: create_body.name,
        description: create_body.description,
      ))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete an edge
        security:
        - bearerAuth: []
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
