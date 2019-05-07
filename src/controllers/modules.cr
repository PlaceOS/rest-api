require "pinger"

require "./application"

module Engine::API
  class Modules < Application
    base "/api/v1/modules/"

    # TODO: Callbacks for access control
    # before_action :check_admin, except: [:index, :state, :show, :ping]
    # before_action :check_support, only: [:index, :state, :show, :ping]

    before_action :find_module, only: [:show, :update, :destroy, :ping]

    # Constant for performance
    MOD_INCLUDE = {
      include: {
        # Most human readable module data is contained in dependency
        dependency: {only: [:name, :description, :module_name, :settings]},

        # include control system on logic modules so it is possible
        # to display the inherited settings
        control_system: {
          only:    [:name, :settings],
          methods: [:zone_data],
        },
      },
    }

    @module : Model::Module?
    getter :module

    private class IndexParams < Params
      attribute system_id : String
      attribute dependency_id : String
      attribute connected : Bool = false
      attribute no_logic : Bool = false
      attribute running : Bool = false
      attribute as_of : Int32
    end

    def index
      args = IndexParams.new(params)

      # if a system id is present we query the database directly
      if args.system_id
        cs = Model::ControlSystem.find!(args.system_id)

        modules = cs.modules || [] of String

        results = Model::Module.find_all(modules).to_a
        render json: {
          total:   results.size,
          results: results,
        }
      else # we use elastic search
        elastic = Model::Module.elastic
        query = elastic.query(params)

        dependency_id = args.dependency_id
        if dependency_id
          query.filter({"doc.dependency_id" => [dependency_id]})
        end

        connected = args.connected
        unless connected.nil?
          query.filter({
            "doc.ignore_connected" => [false],
            "doc.connected"        => [connected],
          })
          unless connected
            query.filter({"doc.ignore_connected" => nil})
            query.should({"doc.ignore_connected" => [false]})
          end
        end

        running = args.running
        if running
          query.filter({"doc.running" => [running]})
        end

        if args.no_logic
          non_logic_roles = [
            Model::Dependency::Role::SSH,
            Model::Dependency::Role::Device,
            Model::Dependency::Role::Service,
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

        query.has_parent(parent: Model::Dependency, parent_index: Model::Dependency.table_name)

        results = elastic.search(query)
        # render json: results.as_json(MOD_INCLUDE)
        render json: results
      end
    end

    def show
      render json: @module
    end

    # TODO: This depends on extended save_and_respond function
    def update
      mod = @module
      return unless mod

      mod.assign_attributes(params)
      # was_running = mod.running
      if mod.save
        # TODO: Update control
        # # Update the running module
        # promise = control.update(id)
        # if was_running
        #   promise.finally do
        #     control.start(id)
        #   end
        # end

        dep = mod.dependency
        serialised = !dep ? mod.to_json : serialise_with_fields(mod, {
          :dependency => restrict_attributes(dep, only: ["name", "module_name"]),
        })

        render json: serialised
      elsif !mod.valid?
        render status: :unprocessable_entity, json: mod.errors.map(&.to_s)
      else
        head :internal_server_error
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

    # def start
    #     # It is possible that module class load can fail
    #     result = control.start(id).value
    #     if result
    #         head :ok
    #     else
    #         render text: "module failed to start", status: :internal_server_error
    #     end
    # end

    # def stop
    #     control.stop(id).value
    #     head :ok
    # end

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

    # ping helper function
    def ping
      if @module.role > 2
        head :not_acceptable
      else
        pinger = Pinger.new(@module.hostname, count: 3)
        pinger.ping
        render json: {
          host:      pinger.ip,
          pingable:  pinger.pingable,
          warning:   pinger.warning,
          exception: pinger.exception,
        }
      end
    end

    private class ModParams < Params
      attribute dependency_id : String
      attribute control_system_id : String
      attribute ip : String
      attribute tls : Bool
      attribute udp : Bool
      attribute port : Int32
      attribute makebreak : Bool
      attribute uri : String
      attribute custom_name : String
      attribute notes : String
      attribute settings : String
      attribute ignore_connected : Bool
      attribute ignore_startstop : Bool
    end

    # protected def lookup_module
    #   mod = control.loaded? id
    #   if mod
    #     yield mod
    #   else
    #     head :not_found
    #   end
    # end

    def find_module
      # Find will raise a 404 (not found) if there is an error
      id = params["id"]?
      @module = Model::Module.find!(id)
    end
  end
end
