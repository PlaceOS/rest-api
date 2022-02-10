require "placeos-frontend-loader/client"

require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Repositories < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/repositories/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :branches, :commits]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt] # brances, commits?

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_repo, only: [:branches, :commits, :destroy, :details, :drivers, :show, :update, :update_alt]
    before_action :body, only: [:create, :update, :update_alt]
    before_action :drivers_only, only: [:drivers, :details]

    # Params
    ###############################################################################################

    getter repository_id : String do
      params["id"]
    end

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

    getter current_repo : Model::Repository { find_repo }

    ###############################################################################################

    private def drivers_only
      unless current_repo.repo_type.driver?
        render_error(:bad_request, "not a driver repository")
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: get all repositories
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Model::Repository}
      YAML
    )]
    def index
      elastic = Model::Repository.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current repository
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::Repository}
      YAML
    )]
    def show
      render json: current_repo
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a repository
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Repository}
        security:
        - bearerAuth: []
        responses:
          422:
            description: Unprocessable Entity
          200:
            description: OK
            content:
              #{Schema.ref Model::Repository}
      YAML
    )]
    def update
      current_repo.assign_attributes_from_json(self.body)

      # Must destroy and re-add to change driver repository URIs
      if current_repo.uri_changed? && current_repo.repo_type.driver?
        return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "`uri` of Driver repositories cannot change")
      end

      save_and_respond current_repo
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
    summary: Update a repository
    requestBody:
      required: true
      content:
        #{Schema.ref Model::Repository}
    security:
    - bearerAuth: []
    responses:
      422:
        description: Unprocessable Entity
      200:
        description: OK
        content:
          #{Schema.ref Model::Repository}
    YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a repository
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Repository}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Model::Repository}
      YAML
    )]
    def create
      save_and_respond(Model::Repository.from_json(self.body))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a repository
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_repo.destroy
      head :ok
    end

    post("/:id/pull", :pull, annotations: @[OpenAPI(<<-YAML
      summary: Pull repository at given id
      security:
      - bearerAuth: []
      responses:
        408:
          description: Request Timeout
        200:
          description: OK
        404:
          description: Not Found
      YAML
    )]) do
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

      found_repo = Utils::Changefeeds.await_model_change(repository, 3.minutes) do |updated|
        updated.destroyed? || !updated.should_pull?
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
    get("/interfaces", :loaded_interfaces, annotations: @[OpenAPI(<<-YAML
      summary: Returns a hash of folder_name to commit
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      render json: PlaceOS::FrontendLoader::Client.client(&.loaded)
    end

    get("/:id/drivers", :drivers, annotations: @[OpenAPI(<<-YAML
      summary: Returns drivers in repository specified by the given id
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      repository_folder = current_repo.folder_name

      # Request to core:
      # "/api/core/v1/drivers/?repository=#{repository}"
      # Returns: `["path/to/file.cr"]`
      drivers = Api::Systems.core_for(repository_folder, request_id) do |core_client|
        core_client.drivers(repository_folder)
      end

      render json: drivers
    end

    get("/:id/commits", :commits, annotations: @[OpenAPI(<<-YAML
      summary: Returns a commits in repository specified by the given id
      parameters:
          #{Schema.qp "limit", "The maximum numbers of commits to return", type: "integer"}
          #{Schema.qp "driver", "file_name of driver", type: "string"}
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      render json: Api::Repositories.commits(
        repository: current_repo,
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

    get("/:id/details", :details, annotations: @[OpenAPI(<<-YAML
      summary: Returns a details of a commit of a driver in a repository specified by the given id
      parameters:
          #{Schema.qp "driver", "Name of driver", type: "string"}
          #{Schema.qp "commit", "Name of commit", type: "string"}
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
      driver_filename = required_param(driver)
      commit = params["commit"]

      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/details?repository=#{repository}&count=#{number_of_commits}"
      # Returns: https://github.com/placeos/driver/blob/master/docs/command_line_options.md#discovery-and-defaults
      details = Api::Systems.core_for(driver_filename, request_id) do |core_client|
        core_client.driver_details(driver_filename, commit, current_repo.folder_name)
      end

      # The raw JSON string is returned
      response.headers["Content-Type"] = "application/json"
      render text: details
    end

    get("/:id/branches", :branches, annotations: @[OpenAPI(<<-YAML
      summary: Returns the branches of a repository specified by the given id
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
      YAML
    )]) do
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
        FrontendLoader::Client.client(request_id: request_id) do |frontends_client|
          frontends_client.branches(repository.folder_name)
        end
      in .driver?
        Api::Systems.core_for(repository.id.as(String), request_id) do |core_client|
          core_client.branches?(repository.folder_name)
        end
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
      Log.context.set(repository_id: repository_id)
      # Find will raise a 404 (not found) if there is an error
      Model::Repository.find!(repository_id, runopts: {"read_mode" => "majority"})
    end
  end
end
