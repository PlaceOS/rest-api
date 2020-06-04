require "placeos-frontends/client"

require "./application"

module PlaceOS::Api
  class Repositories < Application
    base "/api/engine/v2/repositories/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_repo, only: [:show, :update, :update_alt, :destroy, :drivers, :commits, :details]

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

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Repository.from_json(request.body.as(IO)))
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
        head :request_timeout
      end
    end

    def self.pull_repository(repository : Model::Repository)
      # Set the repository commit hash to head
      repository.update_fields(commit_hash: "HEAD")

      # Initiate changefeed on the document's commit_hash
      changefeed = Model::Repository.changes(repository.id.as(String))

      # Wait until the commit hash is not head with a timeout of 20 seconds
      found_repo = begin
        channel = Channel(Model::Repository?).new(1)

        spawn do
          update_event = changefeed.find do |event|
            repo = event[:value]
            repo.destroyed? || repo.commit_hash != "HEAD"
          end
          channel.send(update_event.try &.[:value])
        end

        select
        when received = channel.receive
          received
        when timeout(20.seconds)
          raise "timeout waiting for repository update"
        end
      rescue
        nil
      ensure
        # Terminate the changefeed
        changefeed.stop
      end

      {found_repo.destroyed?, found_repo.commit_hash} if found_repo
    end

    # Determine loaded interfaces and their current commit
    #
    # Returns a hash of folder_name to commit
    get "/interfaces", :loaded_interfaces do
      render json: PlaceOS::Frontends::Client.client(&.loaded)
    end

    get "/:id/drivers", :drivers do
      repository = current_repo.folder_name.as(String)

      # Request to core:
      # "/api/core/v1/drivers/?repository=#{repository}"
      # Returns: `["path/to/file.cr"]`
      drivers = Api::Systems.core_for(repository, request_id) do |core_client|
        core_client.drivers(repository)
      end

      render json: drivers
    end

    get "/:id/commits", :commits do
      number_of_commits = params["count"]?.try &.to_i
      file_name = params["driver"]?

      commits = Api::Repositories.commits(
        repository: current_repo,
        request_id: request_id,
        number_of_commits: number_of_commits,
        file_name: file_name,
      )

      render json: commits
    end

    def self.commits(repository : Model::Repository, request_id : String, number_of_commits : Int32? = nil, file_name : String? = nil)
      number_of_commits = 50 if number_of_commits.nil?
      repository_directory = repository.folder_name.as(String)
      if repository.repo_type == Model::Repository::Type::Driver
        # Dial the core responsible for the driver
        Api::Systems.core_for(repository_directory, request_id) do |core_client|
          core_client.driver(file_name || ".", repository_directory, number_of_commits)
        end
      else
        # Dial the frontends service
        Frontends::Client.client(request_id: request_id) do |frontends_client|
          frontends_client.commits(repository_directory, number_of_commits)
        end
      end
    end

    get "/:id/details", :details do
      repository = current_repo.folder_name.not_nil!
      driver = params["driver"]
      commit = params["commit"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/details?repository=#{repository}&count=#{number_of_commits}"
      # Returns: https://github.com/placeos/driver/blob/master/docs/command_line_options.md#discovery-and-defaults
      details = Api::Systems.core_for(driver, request_id) do |core_client|
        core_client.driver_details(driver, commit, repository)
      end

      # The raw JSON string is returned
      response.headers["Content-Type"] = "application/json"
      render text: details
    end

    #  Helpers
    ###########################################################################

    def current_repo : Model::Repository
      @repo || find_repo
    end

    def find_repo
      id = params["id"]
      Log.context.set(repository_id: id)
      # Find will raise a 404 (not found) if there is an error
      @repo = Model::Repository.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
