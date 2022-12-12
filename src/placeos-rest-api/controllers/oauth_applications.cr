require "./application"

module PlaceOS::Api
  class OAuthApplications < Application
    base "/api/engine/v2/oauth_apps/"

    # Scopes
    ###############################################################################################

    before_action :check_admin
    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_app(id : String)
      Log.context.set(application_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_app = Model::DoorkeeperApplication.find!(id)
    end

    getter! current_app : Model::DoorkeeperApplication

    ###############################################################################################

    # lists the frontend applications enabled on the domains
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "the ID of the domain to be listed", example: "auth-12345")]
      authority_id : String? = nil
    ) : Array(Model::DoorkeeperApplication)
      elastic = Model::DoorkeeperApplication.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)

      # Filter by authority_id
      if authority = authority_id
        query.must({
          "owner_id" => [authority],
        })
      end

      paginate_results(elastic, query)
    end

    # show the details of the applications
    @[AC::Route::GET("/:id")]
    def show : Model::DoorkeeperApplication
      current_app
    end

    # udpate an application
    @[AC::Route::PATCH("/:id", body: :app)]
    @[AC::Route::PUT("/:id", body: :app)]
    def update(app : Model::DoorkeeperApplication) : Model::DoorkeeperApplication
      current = current_app
      current.assign_attributes(app)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new user interface application
    @[AC::Route::POST("/", body: :app, status_code: HTTP::Status::CREATED)]
    def create(app : Model::DoorkeeperApplication) : Model::DoorkeeperApplication
      raise Error::ModelValidation.new(app.errors) unless app.save
      app
    end

    # remove an application
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_app.destroy
    end
  end
end
