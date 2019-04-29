require "./application"

module Engine::API
  class Modules < Application
    base "/api/v1/modules/"

    before_action :check_admin, except: [:index, :state, :show, :ping]
    before_action :check_support, only: [:index, :state, :show, :ping]
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
        cs = ControlSystem.find(args.system_id)

        results = Module.find_all(cs.modules).to_a
        render json: {
          total:   results.length,
          results: results,
        }
      else # we use elastic search
        query = Module.elastic.query(params)

        if args.dependency_id
          query.filter({"doc.dependency_id" => [args.dependency_id]})
        end

        if args.connected
          query.filter({"doc.ignore_connected" => [false]})
          query.filter({"doc.connected" => [args.connected]})

          unless connected
            query.should([{term: {"doc.ignore_connected" => false}},
                          {missing: {field: "doc.ignore_connected"}}])
          end
        end

        if args.running
          query.filter({"doc.running" => [args.running]})
        end

        if args.no_logic
          query.filter({"doc.role" => [0, 1, 2]})
        end

        if args.as_of
          query.filter({
            range: {
              "doc.updated_at" => {
                lte: args.as_of,
              },
            },
          })
        end

        query.has_parent(name: Dependency.name, index: Dependency.table_name)

        results = Module.elastic.search(query)
        # render json: results.as_json(MOD_INCLUDE)
        render json: results
      end
    end

    def show
      render json: @mod
    end

    # Restrict model attributes
    def restrict_attributes(model, only = nil, exclude = nil)
      attr = model.attributes
      attr = attr.select(only) if only
      attr = attr.reject(exclude) if exclude
      attr
    end

    # TODO: This depends on extended save_and_respond function
    def update
      @mod.assign_attributes(params)
      was_running = @mod.running

      if @mod.save
        # Update the running module
        promise = control.update(id)
        if was_running
          promise.finally do
            control.start(id)
          end
        end

        collected_attributes = @mod.attributes.merge!({
          :dependency => restrict_attributes(@mod.dependency, only: [:name, :module_name]),
        })
        render json: collected_attributes
      elsif !@mod.valid?
        render status: :unprocessable_entity, json: self.errors
      else
        head :internal_server_error
      end
    end

    def create
      mod = Module.new(params)
      save_and_respond mod
    end

    def destroy
      @mod.destroy!
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
    # def ping
    #     if @mod.role > 2
    #         head :not_acceptable
    #     else
    #         ping = ::UV::Ping.new(@mod.hostname, count: 3)
    #         ping.ping
    #         render json: {
    #             host: ping.ip,
    #             pingable: ping.pingable,
    #             warning: ping.warning,
    #             exception: ping.exception
    #         }
    #     end
    # end

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

    protected def lookup_module
      mod = control.loaded? id
      if mod
        yield mod
      else
        head :not_found
      end
    end

    def find_module
      # Find will raise a 404 (not found) if there is an error
      @mod = Module.find!(id)
    end
  end
end
