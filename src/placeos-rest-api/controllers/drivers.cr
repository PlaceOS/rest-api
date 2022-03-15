require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Drivers < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/drivers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_driver, only: [:show, :update, :update_alt, :destroy, :recompile]
    before_action :body, only: [:create, :update, :update_alt]

    ###############################################################################################

    getter current_driver : Model::Driver { find_driver }

    @[OpenAPI(
      <<-YAML
        summary: get drivers
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      # Pick off role from HTTP params, render error if present and invalid
      # TODO: This is an example of a need to improve validation model of params.
      param(role : String?, description: "filter by role")
      role = params["role"]?.try &.to_i?.try do |r|
        parsed = Model::Driver::Role.from_value?(r)
        return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "Invalid `role`") if parsed.nil?
        parsed
      end

      elastic = Model::Driver.elastic
      query = elastic.query(params)

      if role
        query.filter({
          "role" => [role.to_i],
        })
      end

      query.search_field "name"
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query), type: Array(Model::Driver)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current driver
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      param(compilation_status : String?, description: "include compilation status in render")
      include_compilation_status = boolean_param("compilation_status", default: true)

      result = !include_compilation_status ? current_driver : with_fields(current_driver, {
        :compilation_status => Api::Drivers.compilation_status(current_driver, request_id),
      })

      render json: result, type: Model::Driver
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a driver
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      current_driver.assign_attributes_from_json(body_raw Model::Driver)

      # Must destroy and re-add to change driver type
      return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "Driver role must not change") if current_driver.role_changed?

      save_and_respond current_driver
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a driver
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      driver = body_as Model::Driver, constructor: :from_json
      save_and_respond(driver)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a driver
        security:
        - bearerAuth: []
      YAML
    )]
    def destroy
      current_driver.destroy
      head :ok
    end

    post("/:id/recompile", :recompile, annotations: @[OpenAPI(<<-YAML
    summary: Attempt to recompile driver with given ID
    security:
    - bearerAuth: []
    YAML
    )]) do
      if current_driver.commit.starts_with?("RECOMPILE")
        head :already_reported
      else
        if (recompiled = Drivers.recompile(current_driver))
          if recompiled.destroyed?
            head :not_found
          else
            render json: recompiled
          end
        else
          head :request_timeout
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
    #
    get("/:id/compiled", :compiled, annotations: @[OpenAPI(<<-YAML
    summary: Check if the core responsible for the driver has finished compilation
    security:
    - bearerAuth: []
    YAML
    )]) do
      if (repository = current_driver.repository).nil?
        Log.error { {repository_id: current_driver.repository_id, message: "failed to load driver's repository"} }
        head :internal_server_error
      end

      compiled = self.class.driver_compiled?(current_driver, repository, request_id)

      Log.info { "#{compiled ? "" : "not "}compiled" }

      if compiled
        # Driver binary present
        head :ok
      else
        if current_driver.compilation_output.nil?
          # Driver not compiled yet
          head :not_found
        else
          # Driver previously failed to compile
          render :service_unavailable, json: {compilation_output: current_driver.compilation_output}
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

    #  Helpers
    ###########################################################################

    protected def find_driver
      id = params["id"]
      Log.context.set(driver_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Driver.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
