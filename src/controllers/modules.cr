require "pinger"

require "./application"

module Engine::API
  class Modules < Application
    base "/api/v1/modules/"

    # TODO: Callbacks for access control
    # before_action :check_admin, except: [:index, :state, :show, :ping]
    # before_action :check_support, only: [:index, :state, :show, :ping]

    before_action :ensure_json, only: [:create, :update]
    before_action :find_module, only: [:show, :update, :destroy, :ping]

    @module : Model::Module?
    getter :module

    private class IndexParams < Params
      attribute as_of : Int32
      attribute control_system_id : String
      attribute connected : Bool
      attribute driver_id : String
      attribute no_logic : Bool = false
      attribute running : Bool
    end

    def index
      args = IndexParams.new(params)

      # if a system id is present we query the database directly
      if args.control_system_id
        cs = Model::ControlSystem.find!(args.control_system_id)
        modules = cs.modules || [] of String
        results = Model::Module.find_all(modules).to_a
        render json: {
          total:   results.size,
          results: results,
        }
      else # we use elastic search
        elastic = Model::Module.elastic
        query = elastic.query(params)

        if args.driver_id
          query.filter({"doc.driver_id" => [args.driver_id.not_nil!]})
        end

        if args.connected
          connected = args.connected.not_nil!
          query.filter({
            "doc.ignore_connected" => [false],
            "doc.connected"        => [connected],
          })
          unless connected
            query.filter({"doc.ignore_connected" => nil})
            query.should({"doc.ignore_connected" => [false]})
          end
        end

        if args.running
          query.filter({"doc.running" => [args.running.not_nil!]})
        end

        if args.no_logic
          non_logic_roles = [
            Model::Driver::Role::SSH,
            Model::Driver::Role::Device,
            Model::Driver::Role::Service,
          ].map(&.to_i)

          query.filter({"doc.role" => non_logic_roles})
        end

        # TODO: Awaiting range query support in neuroplastic
        # as_of = args.as_of
        # if as_of
        #   query.range({
        #     "doc.updated_at" => {
        #       :lte => as_of,
        #     },
        #   })
        # end

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
      render json: @module
    end

    def update
      mod = @module.not_nil!
      body = request.body.not_nil!
      mod.assign_attributes_from_json(body)
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
      body = request.body.not_nil!
      save_and_respond(Model::Module.from_json(body))
    end

    def destroy
      @module.try &.destroy
      head :ok
    end

    ##
    # Additional Functions:
    ##

    post(":id/start", :start) do
      mod = @module.not_nil!
      head :ok if mod.running == true

      mod.update_fields(running: true)
      if mod.running_changed?
        head :internal_server_error
      else
        head :ok
      end
    end

    post(":id/stop", :stop) do
      mod = @module.not_nil!
      head :ok if mod.running == false

      mod.update_fields(running: false)
      if mod.running_changed?
        head :internal_server_error
      else
        head :ok
      end
    end

    # # Returns the value of the requested status variable
    # # Or dumps the complete status state of the module
    # def state
    #     lookup_module do |mod|
    #         para = params.permit(:lookup)
    #         if para.has_key?(:lookup)
    #             render json: mod.status[para[:lookup].to_sym]
    #         else
    #             render json: mod.status.marshal_dump
    #         end
    #     end
    # end

    post(":id/ping", :ping) do
      mod = @module.not_nil!
      if mod.role == Model::Driver::Role::Logic
        head :not_acceptable
      else
        pinger = Pinger.new(mod.hostname.not_nil!, count: 3)
        pinger.ping
        render json: {
          host:      pinger.ip.to_s,
          pingable:  pinger.pingable,
          warning:   pinger.warning,
          exception: pinger.exception,
        }
      end
    end

    def find_module
      # Find will raise a 404 (not found) if there is an error
      @module = Model::Module.find!(params["id"]?)
    end
  end
end
