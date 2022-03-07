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

    # Callbacks
    ###############################################################################################

    before_action :current_driver, only: [:show, :update, :update_alt, :destroy, :recompile]
    before_action :body, only: [:create, :update, :update_alt]

    ###############################################################################################

    getter current_driver : Model::Driver { find_driver }

    def index
      # Pick off role from HTTP params, render error if present and invalid
      # TODO: This is an example of a need to improve validation model of params.
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
      render json: paginate_results(elastic, query)
    end

    def show
      include_compilation_status = boolean_param("compilation_status", default: true)

      result = !include_compilation_status ? current_driver : with_fields(current_driver, {
        :compilation_status => Api::Drivers.driver_compiled?(current_driver, request_id),
      })

      render json: result
    end

    def update
      current_driver.assign_attributes_from_json(self.body)

      # Must destroy and re-add to change driver type
      return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "Driver role must not change") if current_driver.role_changed?

      save_and_respond current_driver
    end

    put_redirect

    def create
      save_and_respond(Model::Driver.from_json(self.body))
    end

    def destroy
      current_driver.destroy
      head :ok
    end

    post("/:id/recompile", :recompile) do
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

    # Check if build has finished compilation of the driver
    #
    get("/:id/compiled", :compiled) do
      compiled = self.class.driver_compiled?(current_driver, request_id)

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

    def self.driver_compiled?(driver : Model::Driver, request_id : String) : Bool
      repository = driver.repository.not_nil!

      !!Build::Client.client &.compiled(
        file: driver.file_name,
        url: repository.uri,
        commit: driver.commit,
        username: repository.username,
        password: repository.decrypt_password,
        request_id: request_id,
      )
    rescue e
      Log.error(exception: e) { "failed to request driver compilation status from build" }
      false
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
