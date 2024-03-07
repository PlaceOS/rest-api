require "./application"

module PlaceOS::Api
  class Clients < Application
    base "/api/engine/v2/clients/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_client(id : String)
      Log.context.set(client_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_client = Model::Client.find!(id)
    end

    getter! current_client : Model::Client

    ###############################################################################################

    # list the clients (all when current authority doesn't have any associated client) or (only clients which belong to this particular client)
    @[AC::Route::GET("/")]
    def index : Array(Model::Client)
      if cid = current_authority.try &.client_id
        Model::Client.where("id = ? or parent_id = ?", cid, cid).to_a
      else
        Model::Client.all.to_a
      end
    end

    # show the selected client
    @[AC::Route::GET("/:id")]
    def show : Model::Client
      current_client
    end

    # udpate a client details
    @[AC::Route::PATCH("/:id", body: :client)]
    @[AC::Route::PUT("/:id", body: :client)]
    def update(client : Model::Client) : Model::Client
      current = current_client
      current.assign_attributes(client)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new client
    @[AC::Route::POST("/", body: :client, status_code: HTTP::Status::CREATED)]
    def create(client : Model::Client) : Model::Client
      raise Error::ModelValidation.new(client.errors) unless client.save
      client
    end

    # remove a client
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_client.destroy
    end
  end
end
