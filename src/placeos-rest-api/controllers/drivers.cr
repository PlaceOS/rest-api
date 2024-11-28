require "./application"

module PlaceOS::Api
  class Drivers < Application
    base "/api/engine/v2/drivers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_driver(id : String)
      Log.context.set(driver_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_driver = ::PlaceOS::Model::Driver.find!(id)
    end

    getter! current_driver : ::PlaceOS::Model::Driver

    # Response helpers
    ###############################################################################################

    # extend the ControlSystem model to handle our return values
    class ::PlaceOS::Model::Driver
      @[JSON::Field(key: "compilation_status")]
      property compilation_status_details : Hash(String, Bool)? = nil
    end

    ###############################################################################################

    # list the drivers available on a cluster
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter by the type of driver", example: "Logic")]
      role : ::PlaceOS::Model::Driver::Role? = nil,
      @[AC::Param::Info(description: "list only drivers for which update is available", example: "true")]
      update_available : Bool? = nil
    ) : Array(::PlaceOS::Model::Driver)
      elastic = ::PlaceOS::Model::Driver.elastic
      query = elastic.query(search_params)

      if role
        query.filter({
          "role" => [role.to_i],
        })
      end

      if update_available
        query.filter({
          "update_available" => [update_available.as(Bool)],
        })
      end

      query.search_field "name"
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # view the details of a driver
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "compilation_status", description: "check if the driver is compiled?", example: "false")]
      include_compilation_status : Bool = true
    ) : ::PlaceOS::Model::Driver
      current_driver.compilation_status_details = Api::Drivers.compilation_status(current_driver, request_id) if include_compilation_status
      current_driver
    end

    # udpate a drivers details
    @[AC::Route::PATCH("/:id", body: :driver)]
    @[AC::Route::PUT("/:id", body: :driver)]
    def update(driver : ::PlaceOS::Model::Driver) : ::PlaceOS::Model::Driver
      current = current_driver
      current.assign_attributes(driver)
      raise Error::ModelValidation.new({ActiveModel::Error.new(current_driver, :role, "Driver role must not change")}) if current_driver.role_changed?
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new driver to the cluster
    @[AC::Route::POST("/", body: :driver, status_code: HTTP::Status::CREATED)]
    def create(driver : ::PlaceOS::Model::Driver) : ::PlaceOS::Model::Driver
      raise Error::ModelValidation.new(driver.errors) unless driver.save
      driver
    end

    # remove a driver and its modules from a cluster
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_driver.destroy
    end

    # force recompile a driver, useful if libraries and supporting files have been updated
    @[AC::Route::POST("/:id/recompile")]
    def recompile : String
      if (repository = current_driver.repository).nil?
        Log.error { {repository_id: current_driver.repository_id, message: "failed to load driver's repository"} }
        raise "failed to load driver's repository"
      end

      resp = self.class.driver_recompile(current_driver, repository, request_id)

      unless 200 <= resp.first <= 299
        render status: resp.first, text: resp.last
      end

      resp = self.class.driver_reload(current_driver, request_id)

      render status: resp.first, text: resp.last
    end

    def self.driver_recompile(driver : ::PlaceOS::Model::Driver, repository : ::PlaceOS::Model::Repository, request_id : String)
      Api::Systems.core_for(driver.file_name, request_id) do |core_client|
        core_client.driver_recompile(
          file_name: URI.encode_path(driver.file_name),
          commit: driver.commit,
          repository: repository.folder_name,
          tag: driver.id.as(String),
        )
      end
    rescue e
      Log.error(exception: e) { "failed to request driver recompilation from core" }
      {500, e.message || "failed to request driver recompilation"}
    end

    def self.driver_reload(driver : ::PlaceOS::Model::Driver, request_id : String) : Tuple(Int32, String)
      cores = RemoteDriver.default_discovery.node_hash
      channel = Channel(Tuple(Int32, String)).new(cores.size)
      cores.each do |cid, core_uri|
        ->(core_id : String, uri : URI) do
          spawn do
            client = PlaceOS::Core::Client.new(uri: uri, request_id: request_id)
            resp = client.driver_reload(driver.id.as(String))
            channel.send(resp)
          rescue error
            Log.error(exception: error) { {
              message:    "failure to request a driver reload on core node",
              core_uri:   uri.to_s,
              core_id:    core_id,
              driver:     driver.id.as(String),
              request_id: request_id,
            } }
            channel.send({500, "failed to request a driver reload on core #{uri}: error: #{error.message}"})
          end
        end.call(cid, core_uri)
      end

      Fiber.yield

      resps = cores.map do |_, _|
        channel.receive
      end

      if resps.all? { |resp| 200 <= resp.first <= 299 }
        {200, resps.last.last}
      elsif resps.all? { |resp| resp.first >= 300 }
        {422, "Unable to reload driver on all core cluster"}
      else
        failed = resps.reject { |resp| 200 <= resp.first <= 299 }
        {417, failed.first.last}
      end
    end

    # Check if the driver is available on the cluster
    @[AC::Route::GET("/:id/compiled", status: {
      NamedTuple(compilation_output: String) => HTTP::Status::SERVICE_UNAVAILABLE,
    })]
    def compiled : Nil | NamedTuple(compilation_output: String)
      if (repository = current_driver.repository).nil?
        Log.error { {repository_id: current_driver.repository_id, message: "failed to load driver's repository"} }
        raise "failed to load driver's repository"
      end

      raise Error::NotFound.new("Driver not compiled yet") if current_driver.recompile_commit?

      compiled = self.class.driver_compiled?(current_driver, repository, request_id)
      Log.info { "#{compiled ? "" : "not "}compiled" }

      unless compiled
        if current_driver.compilation_output.nil?
          # Driver not compiled yet
          raise Error::NotFound.new("Driver not compiled yet")
        else
          # Driver previously failed to compile
          {compilation_output: current_driver.compilation_output.not_nil!}
        end
      end
    end

    def self.driver_compiled?(driver : ::PlaceOS::Model::Driver, repository : ::PlaceOS::Model::Repository, request_id : String, key : String? = nil) : Bool
      Api::Systems.core_for(key.presence || driver.file_name, request_id) do |core_client|
        core_client.driver_compiled?(
          file_name: URI.encode_path(driver.file_name),
          repository: repository.folder_name,
          commit: driver.commit,
          tag: driver.id.as(String),
        )
      end
    rescue e
      Log.error(exception: e) { "failed to request driver compilation status from core" }
      false
    end

    # Returns the compilation status of a driver across the cluster
    def self.compilation_status(
      driver : ::PlaceOS::Model::Driver,
      request_id : String? = "migrate to Log"
    ) : Hash(String, Bool)
      tag = driver.id.as(String)
      repository_folder = driver.repository!.folder_name

      nodes = RemoteDriver.default_discovery.node_hash
      result = Promise.all(nodes.map { |name, uri|
        Promise.defer {
          status = begin
            Core::Client.client(uri, request_id) { |client|
              client.driver_compiled?(driver.file_name, driver.commit, repository_folder, tag)
            }
          rescue e
            Log.error(exception: e) { "failed to request compilation status from core" }
            false
          end
          {name, status}
        }
      }).get

      result.to_h
    end
  end
end
