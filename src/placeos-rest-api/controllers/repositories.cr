require "placeos-build/client"
require "placeos-frontend-loader/client"

require "./application"

module PlaceOS::Api
  class Repositories < Application
    base "/api/engine/v2/repositories/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :branches, :commits]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt] # brances, commits?

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_repository, only: [:branches, :commits, :destroy, :details, :drivers, :show, :update, :update_alt]
    before_action :body, only: [:create, :update, :update_alt]
    before_action :drivers_only, only: [:drivers, :details]

    private def drivers_only
      unless current_repository.repo_type.driver?
        render_error(:bad_request, "not a driver repository")
      end
    end

    getter current_repository : Model::Repository do
      id = params["id"]
      Log.context.set(repository_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Repository.find!(id, runopts: {"read_mode" => "majority"})
    end

    # Params
    ###############################################################################################

    getter limit : Int32? do
      params["limit"]?.try &.to_i?
    end

    getter driver : String? do
      params["driver"]?.presence
    end

    getter commit : String do
      params["commit"]
    end

    ###############################################################################################

    def index
      elastic = Model::Repository.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_repository
    end

    def update
      current_repository.assign_attributes_from_json(self.body)

      # Must destroy and re-add to change driver repository URIs
      if current_repository.uri_changed? && current_repository.repo_type.driver?
        return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "`uri` of Driver repositories cannot change")
      end

      save_and_respond current_repository
    end

    put_redirect

    def create
      save_and_respond(Model::Repository.from_json(self.body))
    end

    def destroy
      current_repository.destroy
      head :ok
    end

    post "/:id/pull", :pull do
      result = Repositories.pull_repository(current_repository)
      if result
        destroyed, commit_hash = result
        if destroyed
          head :not_found
        else
          render json: {commit_hash: commit_hash}
        end
      else
        return render_error(HTTP::Status::REQUEST_TIMEOUT, "Pull timed out")
      end
    end

    def self.pull_repository(repository : Model::Repository)
      # Trigger a pull event
      spawn do
        sleep 0.1
        repository.pull!
      end

      # Start monitoring changes (we ignore deployed_commit_hash == nil)
      found_repo = Utils::Changefeeds.await_model_change(repository, 3.minutes) do |updated|
        updated.destroyed? || !updated.deployed_commit_hash.nil?
      end

      unless found_repo.nil?
        new_commit = found_repo.deployed_commit_hash
        Log.info { found_repo.destroyed? ? "repository delete during pull" : "repository pulled to #{new_commit}" }
        {found_repo.destroyed?, new_commit}
      end
    end

    # Determine loaded interfaces and their current commit
    #
    # Returns a hash of folder_name to commit
    get "/interfaces", :loaded_interfaces do
      render json: PlaceOS::FrontendLoader::Client.client(&.loaded)
    end

    get "/:id/drivers", :drivers do
      drivers = Build::Client.client &.discover_drivers(
        url: current_repository.uri,
        ref: current_repository.commit_hash || current_repository.branch,
        username: current_repository.username,
        password: current_repository.decrypt_password,
        request_id: request_id,
      )

      render json: drivers
    end

    get "/:id/commits", :commits do
      render json: Api::Repositories.commits(
        repository: current_repository,
        request_id: request_id,
        number_of_commits: limit,
        file_name: driver,
      )
    end

    def self.commits(repository : Model::Repository, request_id : String, number_of_commits : Int32? = nil, file_name : String? = nil)
      number_of_commits = 50 if number_of_commits.nil?
      case repository.repo_type
      in .driver?
        # Dial the core responsible for the driver
        Api::Systems.core_for(repository.folder_name, request_id) do |core_client|
          core_client.driver(file_name || ".", repository.folder_name, repository.branch, number_of_commits)
        end
      in .interface?
        # Dial the frontends service
        FrontendLoader::Client.client(request_id: request_id) do |frontends_client|
          frontends_client.commits(repository.folder_name, repository.branch, number_of_commits)
        end
      end
    end

    get "/:id/details", :details do
      driver_filename = required_param(driver)

      info = Build::Client.client do |client|
        client.metadata(
          file: driver_filename,
          url: current_repository.uri,
          commit: commit,
          username: current_repository.username,
          password: current_repository.password,
          request_id: request_id,
        )
      end

      render json: info
    end

    get "/:id/branches", :branches do
      branches = Api::Repositories.branches(
        repository: current_repository,
        request_id: request_id,
      )

      render json: branches
    end

    def self.branches(repository : Model::Repository, request_id : String)
      case repository.repo_type
      in .interface?
        # Dial the frontends service
        FrontendLoader::Client.client(request_id: request_id) do |frontends_client|
          frontends_client.branches(repository.folder_name)
        end
      in .driver?
        Build::Client.client &.branches(url: repository.uri, request_id: request_id, username: repository.username, password: repository.password)
      end.tap do |result|
        if result.nil?
          Log.info { {
            message:       "failed to retrieve branches",
            repository_id: repository.id,
            folder_name:   repository.folder_name,
            name:          repository.name,
            type:          repository.repo_type.to_s,
          } }
        end
      end
    end

    get "/:id/releases", :releases do
      render_error(HTTP::Status::BAD_REQUEST, "can only get releases for interface repositories") unless current_repository.repo_type.interface?
      releases = Api::Repositories.releases(
        repository: current_repository,
        request_id: request_id,
      )

      render json: releases
    end

    def self.releases(repository : Model::Repository, request_id : String)
      # Dial the frontends service
      FrontendLoader::Client.client(request_id: request_id) do |frontends_client|
        frontends_client.releases(repository.folder_name)
      end.tap do |result|
        if result.nil?
          Log.info { {
            message:       "failed to retrieve releases",
            repository_id: repository.id,
            folder_name:   repository.folder_name,
            name:          repository.name,
            type:          repository.repo_type.to_s,
          } }
        end
      end
    end
  end
end
