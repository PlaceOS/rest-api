require "./application"

module ACAEngine::Api
  class Domains < Application
    base "/api/engine/v2/domains/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_domain, only: [:show, :update, :destroy]

    @domain : Model::Authority?

    def index
      elastic = Model::Authority.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: elastic.search(query)
    end

    def show
      render json: current_domain
    end

    def update
      domain = current_domain
      domain.assign_attributes_from_json(request.body.as(IO))
      save_and_respond domain
    end

    def create
      save_and_respond(Model::Authority.from_json(request.body.as(IO)))
    end

    def destroy
      current_domain.destroy
      head :ok
    end

    #  Helpers
    ###########################################################################

    def current_domain : Model::Authority
      @domain || find_domain
    end

    def find_domain
      # Find will raise a 404 (not found) if there is an error
      @domain = Model::Authority.find!(params["id"]?)
    end
  end
end
