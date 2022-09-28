require "promise"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edges < Application
    base "/api/engine/v2/edges/"

    # Scopes
    ###############################################################################################

    generate_scope_check(::PlaceOS::Model::Edge::CONTROL_SCOPE)

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show, :edge_control]
    before_action :check_support, only: [:index, :show]

    before_action :can_write_edge_control, only: [:edge_control]

    # Callbacks
    ###############################################################################################

    skip_action :set_user_id, only: [:edge_control]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_edge(id : String)
      Log.context.set(edge_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_edge = Model::Edge.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_edge : Model::Edge

    ###############################################################################################

    class_getter connection_manager : ConnectionManager { ConnectionManager.new(core_discovery) }

    # Validate the present of the id and check the secret before routing to core

    @[AC::Route::WebSocket("/control")]
    def edge_control(socket) : Nil
      edge_id = Model::Edge.jwt_edge_id?(user_token)

      if edge_id.nil? || !Model::Edge.exists?(edge_id)
        raise Error::Forbidden.new("not an edge lord")
      else
        Log.info { {edge_id: edge_id, message: "new edge connection"} }
        Edges.connection_manager.add_edge(edge_id, socket)
      end
    end

    @[AC::Route::GET("/:id/token")]
    def token : NamedTuple(token: String)
      raise Error::Forbidden.new("not an admin") unless is_admin?
      {token: current_edge.x_api_key}
    end

    @[AC::Route::GET("/")]
    def index : Array(Model::Edge)
      elastic = Model::Edge.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    @[AC::Route::GET("/:id")]
    def show : Model::Edge
      current_edge
    end

    @[AC::Route::PATCH("/:id", body: :edge)]
    @[AC::Route::PUT("/:id", body: :edge)]
    def update(edge : Model::Edge) : Model::Edge
      current = current_edge
      current.assign_attributes(edge)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::POST("/", body: :create_body, status_code: HTTP::Status::CREATED)]
    def create(create_body : Model::Edge::CreateBody) : Model::Edge::KeyResponse
      user = Model::User.find!(create_body.user_id || current_user.id.as(String))
      new_edge = Model::Edge.for_user(
        user: user,
        name: create_body.name,
        description: create_body.description
      )

      # Ensure instance variable initialised
      new_edge.x_api_key

      raise Error::ModelValidation.new(new_edge.errors) unless new_edge.save
      new_edge.to_key_struct
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_edge.destroy
    end
  end
end

require "./edges/connection_manager"
