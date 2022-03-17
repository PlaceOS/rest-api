require "./application"

module PlaceOS::Api
  class OAuthApplications < Application
    base "/api/engine/v2/oauth_apps/"

    # Scopes
    ###############################################################################################

    before_action :check_admin
    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    # Callbacks
    ###############################################################################################

    before_action :current_app, only: [:show, :update, :update_alt, :destroy]
    before_action :body, only: [:create, :update, :update_alt]

    # Params
    ###############################################################################################

    getter authority_id : String? do
      params["authority_id"]?.presence || params["authority"]?.presence
    end

    ###############################################################################################

    getter current_app : Model::DoorkeeperApplication { find_app }

    def index
      elastic = Model::DoorkeeperApplication.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      # Filter by authority_id
      if authority = authority_id
        query.must({
          "owner_id" => [authority],
        })
      end

      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_app
    end

    def update
      current_app.assign_attributes_from_json(self.body)
      save_and_respond current_app
    end

    def create
      save_and_respond(Model::DoorkeeperApplication.from_json(self.body))
    end

    def destroy
      current_app.destroy
      head :ok
    end

    #  Helpers
    ###########################################################################

    protected def find_app
      id = params["id"]
      Log.context.set(application_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::DoorkeeperApplication.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
