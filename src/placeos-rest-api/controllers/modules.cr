require "pinger"
require "placeos-driver/storage"

require "./application"
require "./settings"

module PlaceOS::Api
  class Modules < Application
    include Utils::CoreHelper

    base "/api/engine/v2/modules/"

    before_action :check_admin, except: [:index, :state, :show, :ping]
    before_action :check_support, only: [:index, :state, :show, :ping]

    before_action :ensure_json, only: [:create, :update, :update_alt, :execute]
    before_action :current_module, only: [:show, :update, :update_alt, :destroy, :ping, :state]

    getter current_module : Model::Module { find_module }

    private class IndexParams < Params
      attribute as_of : Int32?
      attribute control_system_id : String?
      attribute connected : Bool?
      attribute driver_id : String?
      attribute no_logic : Bool = false
      attribute running : Bool?
    end

    DRIVER_ATTRIBUTES = %w(name description)

    def index
      args = IndexParams.new(params)

      # if a system id is present we query the database directly
      if (sys_id = args.control_system_id)
        cs = Model::ControlSystem.find!(sys_id)
        modules = cs.modules || [] of String

        # Include subset of association data with results
        results = Model::Module.find_all(modules).compact_map do |mod|
          driver = mod.driver
          next unless driver

          # Most human readable module data is contained in driver
          driver_field = restrict_attributes(
            driver,
            only: DRIVER_ATTRIBUTES,
          )

          with_fields(mod, {
            :driver   => driver_field,
            :compiled => Api::Modules.driver_compiled?(mod, request_id),
          })
        end.to_a

        set_collection_headers(results.size, Model::Module.table_name)

        render json: results
      else # we use Elasticsearch
        elastic = Model::Module.elastic
        query = elastic.query(params)

        if (driver_id = args.driver_id)
          query.filter({"driver_id" => [driver_id]})
        end

        unless (connected = args.connected).nil?
          query.filter({
            "ignore_connected" => [false],
            "connected"        => [connected],
          })
        end

        unless (running = args.running).nil?
          query.should({"running" => [running]})
        end

        if (as_of = args.as_of)
          query.range({
            "updated_at" => {
              :lte => as_of,
            },
          })
        end

        if args.no_logic
          query.must_not({"role" => [Model::Driver::Role::Logic.to_i]})
        end

        query.has_parent(parent: Model::Driver, parent_index: Model::Driver.table_name)
        search_results = paginate_results(elastic, query)

        # Include subset of association data with results
        includes = search_results.compact_map do |d|
          sys = d.control_system
          driver = d.driver
          next unless driver

          # Most human readable module data is contained in driver
          driver_field = restrict_attributes(
            driver,
            only: DRIVER_ATTRIBUTES,
          )

          # Include control system on Logic modules so it is possible
          # to display the inherited settings
          sys_field = if sys
                        restrict_attributes(
                          sys,
                          only: [
                            "name",
                          ],
                          fields: {
                            :zone_data => sys.zone_data,
                          }
                        )
                      else
                        nil
                      end

          with_fields(d, {
            :control_system => sys_field,
            :driver         => driver_field,
          }.compact)
        end

        render json: includes
      end
    end

    def show
      complete = params["complete"]? == "true"
      mod = current_module

      response = !complete ? mod : with_fields(mod, {
        :driver => restrict_attributes(mod.driver, only: DRIVER_ATTRIBUTES),
      })

      render json: response
    end

    def update
      mod = current_module
      mod.assign_attributes_from_json(request.body.as(IO))

      if mod.save
        driver = mod.driver
        serialised = !driver ? mod : with_fields(mod, {
          :driver => restrict_attributes(driver, only: DRIVER_ATTRIBUTES),
        })

        render json: serialised
      else
        render status: :unprocessable_entity, json: mod.errors.map(&.to_s)
      end
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      body = request.body.as(IO)
      save_and_respond(Model::Module.from_json(body))
    end

    def destroy
      current_module.destroy
      head :ok
    end

    # Receive the collated settings for a module
    #
    get("/:id/settings", :settings) do
      render json: Api::Settings.collated_settings(current_user, current_module)
    end

    # Starts a module
    post("/:id/start", :start) do
      mod = current_module
      head :ok if mod.running == true

      mod.update_fields(running: true)

      # Changes cleared on a successful update
      if mod.running_changed?
        Log.error { {controller: "Modules", action: "start", module_id: mod.id, event: "failed"} }
        head :internal_server_error
      else
        head :ok
      end
    end

    # Stops a module
    post("/:id/stop", :stop) do
      mod = current_module
      head :ok unless mod.running

      mod.update_fields(running: false)

      # Changes cleared on a successful update
      if mod.running_changed?
        Log.error { {controller: "Modules", action: "stop", module_id: mod.id, event: "failed"} }
        head :internal_server_error
      else
        head :ok
      end
    end

    # Executes a command on a module
    post("/:id/exec/:method", :execute) do
      id, method = params["id"], params["method"]
      mod = current_module
      module_name = mod.name
      sys_id = mod.control_system_id.as(String)
      args = Array(JSON::Any).from_json(request.body.as(IO))

      remote_driver = Driver::Proxy::RemoteDriver.new(
        module_id: id,
        sys_id: sys_id,
        module_name: module_name,
        discovery: self.class.core_discovery,
      )

      result = remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )

      response.content_type = "application/json"
      render text: result
    rescue e : Driver::Proxy::RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        sys_id:      sys_id,
        module_id:   id,
        module_name: module_name,
        method:      method,
      } }
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Dumps the complete status state of the module
    get("/:id/state", :state) do
      render json: module_state(current_module)
    end

    # Returns the value of the requested status variable
    get("/:id/state/:key", :state_lookup) do
      render json: module_state(current_module, params["key"])
    end

    post("/:id/ping", :ping) do
      mod = current_module
      if mod.role == Model::Driver::Role::Logic
        Log.debug { {controller: "Modules", action: "ping", module_id: mod.id, role: mod.role.to_s} }
        head :not_acceptable
      else
        pinger = Pinger.new(mod.hostname.as(String), count: 3)
        pinger.ping
        render json: {
          host:      pinger.ip.to_s,
          pingable:  pinger.pingable,
          warning:   pinger.warning,
          exception: pinger.exception,
        }
      end
    end

    post("/:id/load", :load) do
      module_id = current_module.id.as(String)
      load = Api::Systems.core_for(module_id, request_id) do |core_client|
        core_client.load(module_id)
      end

      render json: load
    end

    # Helpers
    ############################################################################

    def self.driver_compiled?(mod : Model::Module, request_id : String)
      driver = mod.driver
      unless driver
        Log.error { "failed to load Module<#{mod.id}>'s Driver<#{mod.driver_id}>" }
        return false
      end

      if (repository = driver.repository).nil?
        Log.error { "failed to load Driver<#{driver.id}>'s Repository<#{driver.repository_id}>" }
        return false
      end

      tag = driver.id.as(String)

      begin
        Api::Systems.core_for(mod.id.as(String), request_id) do |core_client|
          core_client.driver_compiled?(
            file_name: URI.encode(driver.file_name),
            repository: repository.folder_name,
            commit: driver.commit,
            tag: tag,
          )
        end
      rescue e
        Log.error(exception: e) { "failed to request driver status from core" }
        false
      end
    end

    def module_state(mod : Model::Module, key : String? = nil)
      storage = Driver::RedisStorage.new(mod.id.as(String))
      key ? storage[key] : storage.to_h
    end

    # Helpers
    ###############################################################################################

    protected def find_module
      id = params["id"]
      Log.context.set(module_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Module.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
