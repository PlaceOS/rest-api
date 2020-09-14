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

      query.search_field "name"
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
      if driver.commit.starts_with?("RECOMPILE")
        head :already_reported
      else
        if (recompiled = Drivers.recompile(driver))
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

      # Initiate changefeed on the document's commit
      changefeed = Model::Driver.changes(driver.id.as(String))
      channel = Channel(Model::Driver?).new(1)

      # Wait until the commit hash is not head with a timeout of 20 seconds
      found_driver = begin
        spawn do
          update_event = changefeed.find do |event|
            driver_update = event[:value]
            driver_update.destroyed? || !driver_update.commit.starts_with? "RECOMPILE"
          end
          channel.send(update_event.try &.[:value])
        end

        select
        when received = channel.receive
          received
        when timeout(20.seconds)
          raise "timeout waiting for recompile"
        end

        received
      rescue
        nil
      ensure
        channel.close
        # Terminate the changefeed
        changefeed.stop
      end

      found_driver
    end

    # Check if the core responsible for the driver has finished compilation
    #
    get("/:id/compiled", :compiled) do
      driver = current_driver
      file_name = URI.encode(driver.file_name)
      commit = driver.commit
      tag = driver.id.as(String)
      repository = driver.repository

      unless repository
        Log.error { "failed to load Driver<#{driver.id}>'s Repository<#{driver.repository_id}>" }
        head :internal_server_error
      end

      compiled = begin
        Api::Systems.core_for(file_name, request_id) do |core_client|
          core_client.driver_compiled?(file_name: file_name, repository: repository.folder_name, commit: commit, tag: tag)
        end
      rescue e
        Log.error(exception: e) { "failed to request compilation status from core" }
        false
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
      tag = driver.id.as(String)
      repository_folder = driver.repository!.folder_name

      nodes = Api::Systems.core_discovery.node_hash
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

      Hash(String, Bool).from_key_values(result)
    end

    #  Helpers
    ###########################################################################

    def current_driver : Model::Driver
      @driver || find_driver
    end

    def find_driver
      id = params["id"]
      Log.context.set(driver_id: id)
      # Find will raise a 404 (not found) if there is an error
      @driver = Model::Driver.find!(id, runopts: {"read_mode" => "majority"})
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
