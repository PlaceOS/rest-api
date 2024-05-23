require "placeos-frontend-loader/client"
require "git-repository"

require "./application"

module PlaceOS::Api
  class Repositories < Application
    base "/api/engine/v2/repositories/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :branches, :commits]
    before_action :can_write, only: [:create, :update, :destroy, :remove] # brances, commits?

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :loaded_interfaces, :remote_branches, :remote_commits, :remote_default_branch, :remote_tags])]
    def find_current_repo(id : String)
      Log.context.set(repository_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_repo = Model::Repository.find!(id)
    end

    @[AC::Route::Filter(:before_action, only: [:drivers, :details])]
    private def drivers_only
      unless current_repo.repo_type.driver?
        render_error(:bad_request, "not a driver repository")
      end
    end

    getter! current_repo : Model::Repository
    class_property repository_dir : String = File.expand_path("./repositories")

    ###############################################################################################

    # lists the repositories added to the system
    @[AC::Route::GET("/")]
    def index : Array(Model::Repository)
      elastic = Model::Repository.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # returns the details of a saved repository
    @[AC::Route::GET("/:id")]
    def show : Model::Repository
      current_repo
    end

    # updates a repositories details
    @[AC::Route::PATCH("/:id", body: :repo)]
    @[AC::Route::PUT("/:id", body: :repo)]
    def update(repo : Model::Repository) : Model::Repository
      current = current_repo
      current.assign_attributes(repo)

      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new repository, either a frontends or driver repository
    @[AC::Route::POST("/", body: :repo, status_code: HTTP::Status::CREATED)]
    def create(repo : Model::Repository) : Model::Repository
      raise Error::ModelValidation.new(repo.errors) unless repo.save
      repo
    end

    # removes a repository from the server
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_repo.destroy
    end

    # checks the remote for any new commits and pulls them locally
    @[AC::Route::POST("/:id/pull")]
    def pull : NamedTuple(commit_hash: String)
      result = Repositories.pull_repository(current_repo)
      if result
        destroyed, commit_hash = result
        raise Error::NotFound.new("repository has been deleted") if destroyed
        {commit_hash: commit_hash.as(String)}
      else
        raise IO::TimeoutError.new("Pull timed out")
      end
    end

    def self.pull_repository(repository : Model::Repository, timeout = 1.minute)
      # Trigger a pull event
      spawn do
        sleep 0.1
        repository.pull!
      end

      # Start monitoring changes (we ignore deployed_commit_hash == nil)
      found_repo = Utils::Changefeeds.await_model_change(repository, timeout) do |updated|
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
    @[AC::Route::GET("/interfaces")]
    def loaded_interfaces : Hash(String, String)
      PlaceOS::FrontendLoader::Client.client(&.loaded)
    end

    # lists the drivers in a repository
    @[AC::Route::GET("/:id/drivers")]
    def drivers : Array(String)
      password = current_repo.decrypt_password if current_repo.password.presence
      repo = GitRepository.new(current_repo.uri, current_repo.username, password)
      repo.file_list(ref: current_repo.branch, path: "drivers/").select do |file|
        file.ends_with?(".cr") && !file.ends_with?("_spec.cr") && !file.includes?("models")
      end
    end

    # Returns the commits for a repository or file
    @[AC::Route::GET("/:id/commits")]
    def commits(
      @[AC::Param::Info(description: "the maximum number of commits to return", example: "50")]
      limit : Int32? = nil,
      @[AC::Param::Info(description: "the path to the file we want commits for", example: "path/to/file.cr")]
      driver : String? = nil,
      @[AC::Param::Info(description: "the branch to grab commits from", example: "main")]
      branch : String? = nil
    ) : Array(GitRepository::Commit)
      Api::Repositories.commits(
        repository: current_repo,
        request_id: request_id,
        number_of_commits: limit,
        file_name: driver,
        branch: branch,
      )
    end

    def self.commits(repository : Model::Repository, request_id : String, number_of_commits : Int32? = nil, file_name : String? = nil, branch : String? = nil)
      # Dial the frontends service which can provide all the details
      FrontendLoader::Client.client(request_id: request_id) do |frontends_client|
        password = repository.decrypt_password if repository.password.presence
        frontends_client.remote_commits(repository.uri, branch || repository.branch, file_name, number_of_commits, repository.username, password)
      end
    end

    # Returns the metadata of the driver
    # For payload information, look at https://github.com/placeos/driver/blob/master/docs/command_line_options.md#discovery-and-defaults
    @[AC::Route::GET("/:id/details")]
    def details(
      @[AC::Param::Info(name: "driver", description: "the file we would like metadata for", example: "path/to/file.cr")]
      driver_filename : String,
      @[AC::Param::Info(description: "the commit level of the file", example: "3f67a66")]
      commit : String
    ) : Nil
      # Request to core:
      # "/api/core/v1/drivers/#{file_name}/details?repository=#{repository}&commit=#{commit_hash}"
      details = Api::Systems.core_for(driver_filename, request_id) do |core_client|
        core_client.driver_details(driver_filename, commit, current_repo.id.as(String), current_repo.branch)
      end

      # The raw JSON string is returned and we proxy that (no need to encode and decode)
      response.headers["Content-Type"] = "application/json"
      render text: details
    end

    # returns the list of branches in the repository
    @[AC::Route::GET("/:id/branches")]
    def branches : Array(String)
      password = current_repo.decrypt_password if current_repo.password.presence
      repo = GitRepository.new(current_repo.uri, current_repo.username, password)
      repo.branches.keys
    end

    # returns the list of releases in the repository, i.e. github releases
    @[AC::Route::GET("/:id/releases")]
    def releases : Array(String)
      password = current_repo.decrypt_password if current_repo.password.presence
      repo = GitRepository.new(current_repo.uri, current_repo.username, password)
      if repo.is_a?(GitRepository::Releases)
        repo.releases
      else
        [] of String
      end
    end

    # Returns an array of tags for the repository
    @[AC::Route::GET("/:id/tags")]
    def tags : Array(String)
      password = current_repo.decrypt_password if current_repo.password.presence
      repo = GitRepository.new(current_repo.uri, current_repo.username, password)
      repo.tags.keys
    end

    # returns the default branch of the specified repository
    @[AC::Route::GET("/:id/default_branch")]
    def default_branch : String
      password = current_repo.decrypt_password if current_repo.password.presence
      repo = GitRepository.new(current_repo.uri, current_repo.username, password)
      repo.default_branch
    end

    # Remote repository queries
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:remote_branches, :remote_commits, :remote_default_branch, :remote_tags])]
    protected def get_repository_url(
      @[AC::Param::Info(description: "the git url that represents the repository", example: "https://github.com/PlaceOS/drivers.git")]
      @repository_url : String,
      @[AC::Param::Info(description: "a username for access if required", example: "steve")]
      @username : String? = nil,
      @[AC::Param::Info(description: "the password or access token as required", example: "ab34cfe4567")]
      @password : String? = nil
    )
    end

    getter! repository_url : String
    getter username : String? = nil
    getter password : String? = nil

    # returns the default branch of the specified repository
    @[AC::Route::GET("/remote_default_branch")]
    def remote_default_branch : String
      repo = GitRepository.new(repository_url, username, password)
      repo.default_branch
    end

    # lists the branches of the specified repository
    @[AC::Route::GET("/remote_branches")]
    def remote_branches : Array(String)
      repo = GitRepository.new(repository_url, username, password)
      repo.branches.keys
    end

    # lists the commits of the specified repository
    @[AC::Route::GET("/remote_commits")]
    def remote_commits(
      @[AC::Param::Info(description: "the branch to grab commits from", example: "main")]
      branch : String? = nil,
      @[AC::Param::Info(description: "the number of commits to return", example: "50")]
      depth : Int32 = 50
    ) : Array(GitRepository::Commit)
      query_branch = branch || remote_default_branch
      FrontendLoader::Client.client(request_id: request_id) do |frontends_client|
        frontends_client.remote_commits(repository_url, query_branch, nil, depth, username, password)
      end
    end

    # Returns an array of tags for the specified repository
    @[AC::Route::GET("/remote_tags")]
    def remote_tags : Array(String)
      repo = GitRepository.new(repository_url, username, password)
      repo.tags.keys
    end
  end
end
