require "placeos-build/client"
require "placeos-frontends/client"

require "./application"

module PlaceOS::Api
  class Repositories < Application
    base "/api/engine/v2/repositories/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :current_repo, only: [:branches, :commits, :destroy, :details, :drivers, :show, :update, :update_alt]
    before_action :body, only: [:create, :update, :update_alt]
    before_action :drivers_only, only: [:drivers, :details]

    getter current_repo : Model::Repository { find_repo }

    private def drivers_only
      unless current_repo.repo_type.driver?
        render_error(:bad_request, "not a driver repository")
      end
    end

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
      current_repo.assign_attributes_from_json(self.body)

      # Must destroy and re-add to change driver repository URIs
      if current_repo.uri_changed? && current_repo.repo_type.driver?
        return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "`uri` of Driver repositories cannot change")
      end

      save_and_respond current_repo
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Repository.from_json(self.body))
    end

    def destroy
      current_repo.destroy
      head :ok
    end

    post "/:id/pull", :pull do
      result = Repositories.pull_repository(current_repo)
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
      # Keep the repository at `HEAD` if it was previously held at `HEAD`
      reset_to_head = repository.repo_type.interface? && repository.commit_hash == "HEAD"

      # Trigger a pull event
      repository.pull!

      found_repo = find_change(repository) do |repo|
        repo.destroyed? || !repo.should_pull?
      end

      unless found_repo.nil?
        new_commit = found_repo.commit_hash
        Log.info { found_repo.destroyed? ? "repository delete during pull" : "repository pulled to #{new_commit}" }
        found_repo.update_fields(commit_hash: "HEAD") if reset_to_head
        {found_repo.destroyed?, new_commit}
      end
    end

    # Determine loaded interfaces and their current commit
    #
    # Returns a hash of folder_name to commit
    get "/interfaces", :loaded_interfaces do
      render json: PlaceOS::Frontends::Client.client(&.loaded)
    end

    get "/:id/drivers", :drivers do
      repository_folder = current_repo.folder_name

      # Request to core:
      # "/api/core/v1/drivers/?repository=#{repository}"
      # Returns: `["path/to/file.cr"]`
      drivers = Api::Systems.core_for(repository_folder, request_id) do |core_client|
        core_client.drivers(repository_folder)
      end

      render json: drivers
    end

    get "/:id/commits", :commits do
      limit = params["limit"]?.try &.to_i
      file_name = params["driver"]?

      commits = Api::Repositories.commits(
        repository: current_repo,
        request_id: request_id,
        limit: limit,
        file_name: file_name,
      )

      render json: commits
    end

    def self.commits(repository : Model::Repository, request_id : String, file_name : String? = nil, branch : String? = nil, limit : Int32? = nil)
      limit = 50 if limit.nil?
      branch = "master" if branch.nil?

      case repository.repo_type
      in .driver?
        Build::Client.client do |client|
          args = {url: repository.uri, request_id: request_id, count: limit, branch: branch, username: repository.username, password: repository.password}
          if file_name
            client.file_commits(**args.merge({file: file_name}))
          else
            client.repository_commits(**args)
          end
        end
      in .interface?
        # Dial the frontends service
        Frontends::Client.client(request_id: request_id) do |frontends_client|
          frontends_client.commits(repository.folder_name, limit)
        end
      end
    end

    get "/:id/details", :details do
      driver = params["driver"]
      commit = params["commit"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/details?repository=#{repository}&count=#{number_of_commits}"
      # Returns: https://github.com/placeos/driver/blob/master/docs/command_line_options.md#discovery-and-defaults
      details = Api::Systems.core_for(driver, request_id) do |core_client|
        core_client.driver_details(driver, commit, current_repo.folder_name)
      end

      # The raw JSON string is returned
      response.headers["Content-Type"] = "application/json"
      render text: details
    end

    get "/:id/branches", :branches do
      branches = Api::Repositories.branches(
        repository: current_repo,
        request_id: request_id,
      )

      render json: branches
    end

    def self.branches(repository : Model::Repository, request_id : String)
      case repository.repo_type
      in .interface?
        # Dial the frontends service
        Frontends::Client.client(request_id: request_id) do |frontends_client|
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

    #  Helpers
    ###########################################################################

    protected def find_repo
      id = params["id"]
      Log.context.set(repository_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Repository.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
