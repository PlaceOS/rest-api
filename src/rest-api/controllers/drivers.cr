require "./application"

module PlaceOS::Api
  class Drivers < Application
    base "/api/engine/v2/drivers/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_driver, only: [:show, :update, :update_alt, :destroy, :recompile]

    @driver : Model::Driver?

    def index
      # Pick off role from HTTP params, render error if present and invalid
      role = params["role"]?.try &.to_i?.try do |r|
        parsed = Model::Driver::Role.from_value?(r)
        render status: :unprocessable_entity, text: "Invalid Role" unless parsed
        parsed
      end

      elastic = Model::Driver.elastic
      query = elastic.query(params)

      if role
        query.filter({
          "role" => [role.to_i],
        })
      end

      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    def show
      driver = current_driver
      include_compilation_status = !params.has_key?("compilation_status") || params["compilation_status"] != "false"

      if include_compilation_status
        render json: with_fields(driver, {
          :compilation_status => Api::Drivers.compilation_status(driver, request_id),
        })
      else
        render json: driver
      end
    end

    def update
      driver = current_driver
      driver.assign_attributes_from_json(request.body.as(IO))

      # Must destroy and re-add to change driver type
      render :unprocessable_entity, text: "Error: role must not change" if driver.role_changed?

      save_and_respond driver
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Driver.from_json(request.body.as(IO)))
    end

    def destroy
      current_driver.destroy
      head :ok
    end

    post("/:id/recompile", :recompile) do
      driver = current_driver
      commit = driver.commit.not_nil!
      if commit.starts_with?("RECOMPILE")
        head :already_reported
      else
        driver.commit = "RECOMPILE-#{commit}"
        save_and_respond driver
      end
    end

    # Check if the core responsible for the driver has finished compilation
    #
    get("/:id/compiled", :compiled) do
      driver = current_driver
      file_name = URI.encode(driver.file_name.as(String))
      commit = driver.commit.as(String)
      tag = driver.id.as(String)
      repository = driver.repository

      unless repository
        Log.error { "failed to load Driver<#{driver.id}>'s Repository<#{driver.repository_id}>" }
        head :internal_server_error
      end

      compiled = Api::Systems.core_for(file_name, request_id) do |core_client|
        core_client.driver_compiled?(file_name: file_name, repository: repository.folder_name.as(String), commit: commit, tag: tag)
      end

      if compiled
        Log.info { "Driver<#{driver.id}> is compiled" }
        head :ok
      else
        Log.warn { "Driver<#{driver.id}> not compiled" }
        head :not_found
      end
    end

    # Returns the compilation status of a driver across the cluster
    def self.compilation_status(
      driver : Model::Driver,
      request_id : String? = "migrate to Log"
    )
      file_name = driver.file_name.as(String)
      commit = driver.commit.as(String)
      repository_folder = driver.repository.as(Model::Repository).folder_name.as(String)
      tag = driver.id.as(String)

      nodes = Api::Systems.core_discovery.node_hash
      result = Promise.all(nodes.map { |name, uri|
        Promise.defer {
          Core::Client.client(uri, request_id) { |client|
            {name, client.driver_compiled?(file_name, commit, repository_folder, tag)}
          }
        }
      }).get

      Hash(String, Bool).from_key_values(result)
    end

    #  Helpers
    ###########################################################################

    def current_driver : Model::Driver
      @driver || find_driver
    end

    def find_driver
      # Find will raise a 404 (not found) if there is an error
      @driver = Model::Driver.find!(params["id"], runopts: {"read_mode" => "majority"})
    end
  end
end

class Hash(K, V)
  def self.from_key_values(kvs : Array(Tuple(K, V)))
    kvs.each_with_object({} of K => V) do |(k, v), hash|
      hash[k] = v
    end
  end
end
