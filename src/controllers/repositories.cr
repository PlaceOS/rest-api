require "./application"

module ACAEngine::Api
  class Repositories < Application
    base "/api/engine/v2/repositories/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_repo, only: [:show, :update, :destroy]

    @repo : Model::Repository?

    def index
      elastic = Model::Repository.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: elastic.search(query)
    end

    def show
      render json: current_repo
    end

    def update
      repo = current_repo
      repo.assign_attributes_from_json(request.body.as(IO))

      # Must destroy and re-add to change uri
      render :unprocessable_entity, text: "Error: uri must not change" if repo.uri_changed?
      save_and_respond repo
    end

    def create
      save_and_respond(Model::Repository.from_json(request.body.as(IO)))
    end

    def destroy
      current_repo.destroy
      head :ok
    end

    #  Helpers
    ###########################################################################

    def current_repo : Model::Repository
      @repo || find_repo
    end

    def find_repo
      # Find will raise a 404 (not found) if there is an error
      @repo = Model::Repository.find!(params["id"]?)
    end
  end
end
