require "./application"

module ACAEngine::Api
  class Repositories < Application
    base "/api/engine/v2/repositories/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_repo, only: [:show, :update, :destroy, :drivers, :commits, :details]

    @repo : Model::Repository?

    def index
      elastic = Model::Repository.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
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

    put "/" { update }

    def create
      save_and_respond(Model::Repository.from_json(request.body.as(IO)))
    end

    def destroy
      current_repo.destroy
      head :ok
    end

    get "/:id/drivers", :drivers do
      repository = current_repo.folder_name.not_nil!

      # Request to core:
      # "/api/core/v1/drivers/?repository=#{repository}"
      # Returns: `["path/to/file.cr"]`
      core_client = Api::Systems.core_for(repository, logger.request_id)
      render json: core_client.drivers(repository)
    end

    get "/:id/commits", :commits do
      number_of_commits = (params["count"]? || "50").to_i
      repository = current_repo.folder_name.not_nil!
      file_name = params["driver"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/?repository=#{repository}&count=#{number_of_commits}"
      # Returns: `[{commit:, date:, author:, subject:}]`
      core_client = Api::Systems.core_for(repository, logger.request_id)
      render json: core_client.driver(file_name, repository, number_of_commits)
    end

    get "/:id/details", :details do
      repository = current_repo.folder_name.not_nil!
      driver = params["driver"]
      commit = params["commit"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/details?repository=#{repository}&count=#{number_of_commits}"
      # Returns: https://github.com/aca-labs/crystal-engine-driver/blob/master/docs/command_line_options.md#discovery-and-defaults
      core_client = Api::Systems.core_for(driver, logger.request_id)

      # The raw JSON string is returned
      response.headers["Content-Type"] = "Application/json"
      render text: core_client.driver_details(driver, commit, repository)
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
