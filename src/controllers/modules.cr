require "pinger"
require "engine-driver/storage"

require "./application"

module ACAEngine::Api
  class Modules < Application
    include Utils::CoreHelper

    base "/api/engine/v2/modules/"

    before_action :check_admin, except: [:index, :state, :show, :ping]
    before_action :check_support, only: [:index, :state, :show, :ping]

    before_action :ensure_json, only: [:create, :update, :execute]
    before_action :find_module, only: [:show, :update, :destroy, :ping, :state]

    @module : Model::Module?

    private class IndexParams < Params
      attribute as_of : Int32
      attribute control_system_id : String
      attribute connected : Bool
      attribute driver_id : String
      attribute no_logic : Bool = false
      attribute running : Bool
    end

    # TODO: Refactor, a port from ruby-engine
    def index
      args = IndexParams.new(params)

      # if a system id is present we query the database directly
      if (sys_id = args.control_system_id)
        cs = Model::ControlSystem.find!(sys_id)
        modules = cs.modules || [] of String
        results = Model::Module.find_all(modules).to_a
        render json: {
          total:   results.size,
          results: results,
        }
      else # we use Elasticsearch
        elastic = Model::Module.elastic
        query = elastic.query(params)

        if (driver_id = args.driver_id)
          query.filter({"driver_id" => [driver_id]})
        end

        if (connected = args.connected)
          query.filter({
            "ignore_connected" => [false],
            "connected"        => [connected],
          })
          unless connected
            query.filter({"ignore_connected" => nil}) # FIXME: dubious... field with default, unlikely to be nil
            query.should({"ignore_connected" => [false]})
          end
        end

        if (running = args.running)
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
        search_results = elastic.search(query)

        # Include subset of association data with results
        includes = search_results[:results].map do |d|
          sys = d.control_system
          driver = d.driver

          # Most human readable module data is contained in driver
          driver_field = restrict_attributes(
            driver,
            only: [
              "name",
              "description",
              "module_name",
              "settings",
            ]
          )

          # Include control system on logic modules so it is possible
          # to display the inherited settings
          sys_field = restrict_attributes(
            sys,
            only: [
              "name",
              "settings",
            ],
            fields: {
              :zone_data => sys.try &.zone_data,
            }
          )

          with_fields(d, {
            :control_system => sys_field,
            :driver         => driver_field,
          })
        end

        render json: {
          total:   search_results[:total],
          results: includes,
        }
      end
    end

    def show
      render json: current_module
    end

    def update
      mod = current_module
      mod.assign_attributes_from_json(request.body.as(IO))

      if mod.save
        # TODO: Update control; Ruby engine starts the module instance
        driver = mod.driver
        serialised = !driver ? mod : with_fields(mod, {
          :driver => restrict_attributes(driver, only: ["name", "module_name"]),
        })

        render json: serialised
      else
        render status: :unprocessable_entity, json: mod.errors.map(&.to_s)
      end
    end

    def create
      body = request.body.as(IO)
      save_and_respond(Model::Module.from_json(body))
    end

    def destroy
      current_module.destroy
      head :ok
    end

    # Starts a module
    post(":id/start", :start) do
      mod = current_module
      head :ok if mod.running == true

      mod.update_fields(running: true)

      # Changes cleared on a successful update
      if mod.running_changed?
        logger.tag_error(controller: "Modules", action: "start", module_id: mod.id, event: "failed")
        head :internal_server_error
      else
        head :ok
      end
    end

    # Stops a module
    post(":id/stop", :stop) do
      mod = current_module
      head :ok unless mod.running

      mod.update_fields(running: false)

      # Changes cleared on a successful update
      if mod.running_changed?
        logger.tag_error(controller: "Modules", action: "stop", module_id: mod.id, event: "failed")
        head :internal_server_error
      else
        head :ok
      end
    end

    # Executes a command on a module
    post(":id/exec/:method", :execute) do
      id, method = params["id"], params["method"]
      mod = current_module
      module_name = mod.name.as(String)
      sys_id = mod.control_system_id.as(String)
      args = Array(JSON::Any).from_json(request.body.as(IO))

      remote_driver = Driver::Proxy::RemoteDriver.new(
        module_id: id,
        sys_id: sys_id,
        module_name: module_name,
        discovery: Systems.core_discovery,
      )
      response = remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: logger.request_id,
      )
      render json: response
    rescue e : Driver::Proxy::RemoteDriver::Error
      driver_execute_error_response(e)
    rescue e
      logger.tag_error(
        message: "core execute request failed",
        error: e.message,
        sys_id: sys_id,
        module_id: id,
        method: method,
        module_name: module_name,
        backtrace: e.inspect_with_backtrace,
      )
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Dumps the complete status state of the module
    get(":id/state", :state) do
      render json: module_state(current_module)
    end

    # Returns the value of the requested status variable
    get(":id/state/:key", :state_lookup) do
      render json: module_state(current_module, params["key"])
    end

    post(":id/ping", :ping) do
      mod = current_module
      if mod.role == Model::Driver::Role::Logic
        logger.tag_debug(controller: "Modules", action: "ping", module_id: mod.id, role: mod.role)
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

    # Helpers
    ############################################################################

    def module_state(mod : Model::Module, key : String? = nil)
      storage = Driver::Storage.new(mod.id.as(String))
      key ? storage[key] : storage.to_h
    end

    def current_module : Model::Module
      return @module.as(Model::Module) if @module
      find_module
    end

    def find_module
      # Find will raise a 404 (not found) if there is an error
      @module = Model::Module.find!(params["id"]?)
    end
  end
end
