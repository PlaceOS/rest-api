require "./application"

module PlaceOS::Api
  class Drivers < Application
    base "/api/engine/v2/drivers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_driver(id : String)
      Log.context.set(driver_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_driver = Model::Driver.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_driver : Model::Driver

    ###############################################################################################

    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter by the type of driver", example: "Logic")]
      role : Model::Driver::Role? = nil
    ) : Array(Model::Driver)
      elastic = Model::Driver.elastic
      query = elastic.query(search_params)

      if role
        query.filter({
          "role" => [role.to_i],
        })
      end

      query.search_field "name"
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "compilation_status", description: "check if the driver is compiled?", example: "false")]
      include_compilation_status : Bool = true
    ) : Model::Driver | Hash(String, Hash(String, Bool) | JSON::Any)
      # TODO:: find an alternative for with_fields
      !include_compilation_status ? current_driver : with_fields(current_driver, {
        "compilation_status" => Api::Drivers.compilation_status(current_driver, request_id),
      })
    end

    @[AC::Route::PATCH("/:id", body: :driver)]
    @[AC::Route::PUT("/:id", body: :driver)]
    def update(driver : Model::Driver) : Model::Driver
      current = current_driver
      current.assign_attributes(driver)
      raise Error::ModelValidation.new({ActiveModel::Error.new(current_driver, :role, "Driver role must not change")}) if current_driver.role_changed?
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::POST("/", body: :driver, status_code: HTTP::Status::CREATED)]
    def create(driver : Model::Driver) : Model::Driver
      raise Error::ModelValidation.new(driver.errors) unless driver.save
      driver
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_driver.destroy
    end

    @[AC::Route::POST("/:id/recompile", status: {
      Nil => HTTP::Status::ALREADY_REPORTED,
    })]
    def recompile : Model::Driver?
      if current_driver.commit.starts_with?("RECOMPILE")
        nil
      else
        if (recompiled = Drivers.recompile(current_driver))
          if recompiled.destroyed?
            raise Error::NotFound.new("driver was deleted")
          else
            recompiled
          end
        else
          raise IO::TimeoutError.new("time exceeded waiting for driver to recompile")
        end
      end
    end

    def self.recompile(driver : Model::Driver)
      # Set the repository commit hash to head
      driver.update_fields(commit: "RECOMPILE-#{driver.commit}")

      # Wait until the commit hash is not head with a timeout of 90 seconds
      # ameba:disable Style/RedundantReturn
      return Utils::Changefeeds.await_model_change(driver, timeout: 90.seconds) do |update|
        update.destroyed? || !update.recompile_commit?
      end
    end

    # Check if the core responsible for the driver has finished compilation
    @[AC::Route::GET("/:id/compiled", status: {
      NamedTuple(compilation_output: String) => HTTP::Status::SERVICE_UNAVAILABLE,
    })]
    def compiled : Nil | NamedTuple(compilation_output: String)
      if (repository = current_driver.repository).nil?
        Log.error { {repository_id: current_driver.repository_id, message: "failed to load driver's repository"} }
        raise "failed to load driver's repository"
      end

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

    def self.driver_compiled?(driver : Model::Driver, repository : Model::Repository, request_id : String, key : String? = nil) : Bool
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
      driver : Model::Driver,
      request_id : String? = "migrate to Log"
    ) : Hash(String, Bool)
      tag = driver.id.as(String)
      repository_folder = driver.repository!.folder_name

      nodes = core_discovery.node_hash
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
