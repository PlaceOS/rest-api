require "./application"

module PlaceOS::Api
  class Domains < Application
    base "/api/engine/v2/domains/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :current_domain, only: [:show, :update, :update_alt, :destroy]

    getter current_domain : Model::Authority { find_domain }

    def index
      elastic = Model::Authority.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_domain
    end

    def update
      domain = current_domain
      domain.assign_attributes_from_json(request.body.as(IO))
      save_and_respond domain
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Authority.from_json(request.body.as(IO)))
    end

    def destroy
      current_domain.destroy
      head :ok
    end

    #  Helpers
    ###########################################################################

    protected def find_domain
      id = params["id"]
      Log.context.set(authority_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Authority.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
