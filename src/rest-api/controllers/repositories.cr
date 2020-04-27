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
      repository.update_fields(commit_hash: "head")

      # Initiate changefeed on the document's commit_hash
      changefeed = Model::Repository.changes(repository.id.as(String))

      # Wait until the commit hash is not head with a timeout of 20 seconds
      found_repo = begin
        channel = Channel(Model::Repository?).new(1)

        spawn do
          update_event = changefeed.find do |event|
            repo = event[:value]
            repo.destroyed? || repo.commit_hash != "head"
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

    get "/:id/drivers", :drivers do
      repository = current_repo.folder_name.not_nil!

      # Request to core:
      # "/api/core/v1/drivers/?repository=#{repository}"
      # Returns: `["path/to/file.cr"]`
      core_client = Api::Systems.core_for(repository, request_id)
      render json: core_client.drivers(repository)
    end

    get "/:id/commits", :commits do
      number_of_commits = (params["count"]? || "50").to_i
      repository = current_repo.folder_name.not_nil!
      file_name = params["driver"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/?repository=#{repository}&count=#{number_of_commits}"
      # Returns: `[{commit:, date:, author:, subject:}]`
      core_client = Api::Systems.core_for(repository, request_id)
      render json: core_client.driver(file_name, repository, number_of_commits)
    end

    get "/:id/details", :details do
      repository = current_repo.folder_name.not_nil!
      driver = params["driver"]
      commit = params["commit"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/details?repository=#{repository}&count=#{number_of_commits}"
      # Returns: https://github.com/placeos/driver/blob/master/docs/command_line_options.md#discovery-and-defaults
      core_client = Api::Systems.core_for(driver, request_id)

      # The raw JSON string is returned
      response.headers["Content-Type"] = "application/json"
      render text: core_client.driver_details(driver, commit, repository)
    end

    #  Helpers
    ###########################################################################

    def current_repo : Model::Repository
      @repo || find_repo
    end

    def find_repo
      # Find will raise a 404 (not found) if there is an error
      @repo = Model::Repository.find!(params["id"], runopts: {"read_mode" => "majority"})
    end
  end
end
