require "promise"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edges < Application
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

    get("/:id/token", :token) do
      head :forbidden unless is_admin?
      render json: {token: current_edge.x_api_key}
    end

    def index
      elastic = Model::Edge.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_edge
    end

    def update
      current_edge.assign_attributes_from_json(self.body)
      save_and_respond current_edge
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      create_body = Model::Edge::CreateBody.from_json(self.body)
      user = Model::User.find!(create_body.user_id)
      save_and_respond(Model::Edge.for_user(
        user: user,
        name: create_body.name,
        description: create_body.description,
      ))
    end

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
