require "./application"

module PlaceOS::Api
  class OAuthApplications < Application
    base "/api/engine/v2/oauth_apps/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :current_app, only: [:show, :update, :update_alt, :destroy]

    getter current_app : Model::DoorkeeperApplication { find_app }

    def index
      elastic = Model::DoorkeeperApplication.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      # filter by authority
      if params.has_key? "authority"
        query.must({
          "owner_id" => [params["authority"]],
        })
      end

      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_app
    end

    def update
      app = current_app
      app.assign_attributes_from_json(request.body.as(IO))
      save_and_respond app
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::DoorkeeperApplication.from_json(request.body.as(IO)))
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
