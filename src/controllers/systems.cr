require "./application"

module Engine::API
  class Systems < Application
    base "/api/v1/systems/"

    # TODO: Callbacks for access control
    # state, funcs, count and types are available to authenticated users
    # before_action :check_admin, only: [:create, :update, :destroy, :remove, :start, :stop]
    # before_action :find_system, only: [:show, :update, :destroy, :remove, :count, :start, :stop]

    @cs : Model::ControlSystem?

    # Strong params for index method
    class IndexParams < Params
      attribute zone_id : String
      attribute module_id : String
    end

    # Query control system resources
    def index
      query = System.elastic.query(params)
      query.sort = NAME_SORT_ASC
      args = IndexParams.new(params)

      # Filter systems via zone_id
      if args.zone_id
        query.filter({
          "doc.zones" => [args.zone_id],
        })
      end

      # Filter via module_id
      if args.module_id
        query.filter({
          "doc.modules" => [args.module_id],
        })
      end

      query.search_field "doc.name"
      render json: System.elastic.search(query)
    end

    class ShowParams < Params
      attribute complete : Bool
    end

    # Renders a control system
    def show
      args = ShowParams.new(params)
      if args.complete
        complete = @cs.attributes.merge!({
          :module_data => @cs.module_data,
          :zone_data   => @cs.zone_data,
        })
        render json: complete
      else
        render json: @cs
      end
    end

    # Updates a control system
    def update
      version = params[:version]?.try(&.to_i)
      return head :conflict if version && version != @cs.version

      @cs.assign_attributes(params)
      @cs.version += 1
      save_and_respond(@cs)
    end

    class RemoveParams < Params
      attribute module_id : String
    end

    # Removes the module from the system and deletes it if not used elsewhere
    def remove
      args = RemoveParams.new(params)
      module_id = args.module_id
      if module_id && @cs.modules.include? module_id
        @cs.modules_will_change!
        @cs.modules.delete(module_id)
        @cs.save! # with_cas: true

        # keep if any other ControlSystem is using the module
        keep = ControlSystem.using_module(module_id).any? { |cs| cs.id != @cs.id }
        unless keep
          mod = Module.find module_id
          mod.destroy unless mod.nil?
        end
      end

      head :ok
    end

    def create
      cs = ControlSystem.new(params)
      save_and_respond cs
    end

    def destroy
      sys_id = @cs.id

      # Stop all modules in the system
      wait = @cs.cleanup_modules

      reactor.finally(*wait).then {
        @cs.destroy
      }.value

      # Clear the cache
      control.expire_cache(sys_id).value

      head :ok
    end

    ##
    # Additional Functions:
    # TODO: Application specfic functionality
    #
    # # Start modules
    # def start
    #   head :ok
    # end

    # # Stop modules
    # def stop
    #   head :ok
    # end

    # EXEC_PARAMS = [:module, :index, :method]
    # def exec
    #     # Run a function in a system module (async request)
    #     required_params(params, :module, :method)

    #     # This looks insane however it does achieve our out of the ordinary requirement
    #     # .to_h converts to indifferent access .to_h converts to a regular hash and
    #     # .symbolize_keys! is required for passing hashes to functions with named params
    #     # and having them apply correctly
    #     para = params.permit(EXEC_PARAMS).to_h.to_h.symbolize_keys!.tap do |whitelist|
    #         whitelist[:args] = Array(params[:args]).collect { |arg|
    #             if arg.is_a?(::ActionController::Parameters)
    #                 arg.to_unsafe_h.to_h.symbolize_keys!
    #             else
    #                 arg
    #             end
    #         }
    #     end
    #     defer = reactor.defer
    #     sys  = ::Orchestrator::Core::SystemProxy.new(reactor, id, nil, current_user)
    #     mod = sys.get(para[:module], para[:index] || 1)
    #     result = mod.method_missing(para[:method], *para[:args])
    #     # timeout in case message is queued
    #     timeout = reactor.scheduler.in(15000) do
    #         defer.resolve("Wait time exceeded. Command may have been queued.")
    #     end
    #     result.finally do
    #         timeout.cancel # if we have our answer
    #         defer.resolve(result)
    #     end

    #     value = defer.promise.value

    #     begin
    #         # Placed into an array so primitives values are returned as valid JSON
    #         render json: [prepare_json(value)]
    #     rescue e < Exception
    #         # respond with nil if object cannot be converted to JSON
    #         logger.info "failed to convert object #{value.class} to JSON"
    #         render json: ["response object #{value.class} could not be rendered in JSON"]
    #     end
    # rescue e < Exception
    #     render json: ["#{e.message}\n#{e.backtrace.join("\n")}"], status: :internal_server_error
    # end

    # def state
    #   # Status defined as a system module
    #   required_params(params, :module)
    #   sys = System.get(id)
    #   if sys
    #     para = params.permit(:module, :index, :lookup)
    #     index = para[:index]
    #     mod = sys.get(para[:module].to_sym, index.nil? ? 1 : index.to_i)
    #     if mod
    #       if para.has_key?(:lookup)
    #         render json: mod.status[para[:lookup].to_sym]
    #       else
    #         mod.thread.next_tick do
    #           mod.instance.__STATS__
    #         end
    #         render json: mod.status.marshal_dump
    #       end
    #     else
    #       head :not_found
    #     end
    #   else
    #     head :not_found
    #   end
    # end

    #   # returns a list of functions available to call
    #   Ignore = Set.new([
    #       Constants, Transcoder, Core::Mixin, Ssh::Mixin,
    #       Logic::Mixin, Device::Mixin, Service::Mixin
    #   ])

    #   Break = Set.new([
    #       ::ActiveSupport::ToJsonWithActiveSupportEncoder,
    #       Object, Kernel, BasicObject
    #   ])
    #
    #   def funcs
    #       required_params(params, :module)
    #       sys = System.get(id)
    #       if sys
    #           para = params.permit(:module, :index)
    #           index = para[:index]
    #           index = index.nil? ? 1 : index.to_i;

    #           mod = sys.get(para[:module].to_sym, index)
    #           if mod
    #               klass = mod.klass

    #               # Find all the public methods available for calling
    #               # Including those methods from ancestor classes
    #               funcs = []
    #               klass.ancestors.each do |methods|
    #                   break if Break.include?(methods)
    #                   next  if Ignore.include?(methods)
    #                   funcs += methods.public_instance_methods(false)
    #               end

    #               # Remove protected methods
    #               pub = funcs.select { |func| !Core::PROTECTED[func] }

    #               # Provide details on the methods
    #               resp = {}
    #               pub.each do |pfunc|
    #                   meth = klass.instance_method(pfunc.to_sym)
    #                   resp[pfunc] = {
    #                       arity: meth.arity,
    #                       params: meth.parameters
    #                   }
    #               end

    #               render json: resp
    #           else
    #               head :not_found
    #           end
    #       else
    #           head :not_found
    #       end
    #   end

    # class CountParams < Params
    #   attribute id : String, presence: true
    #   attribute module : String, presence: true
    # end

    # # Return the count of a module type in a system
    # def count
    #   args = CountParams.new(params)
    #   args.validate_params!

    #   sys = System.find(args.id)
    #   if sys
    #     render json: {count: sys.count(args.module)}
    #   else
    #     head :not_found
    #   end
    # end

    # # returns a hash of a module types in a system with
    # # the count of each of those types
    # def types
    #   id = params["id"]
    #   sys = System.find(id)
    #   if sys
    #     mods = sys.modules
    #     # mods.delete(:__Triggers__)
    #     result = mods.each_with_object({} of String => Int32) do |mod, counts|
    #       counts[mod] = sys.count(mod)
    #     end
    #     render json: result
    #   else
    #     head :not_found
    #   end
    # end

    # Better performance as don't need to create the object each time
    private CS_PARAMS = [
      :name, :description, :support_url, :installed_ui_devices,
      :capacity, :email, :bookable, :features, :version,
      # {
      #   zones:   [] of String,
      #   modules: [] of String,
      # },
    ]

    # Accepted mass assignment HTTP params
    # :name
    # :description
    # :support_url
    # :installed_ui_devices
    # :capacity
    # :email
    # :bookable
    # :features
    # :version

    protected def find_system
      # Find will raise a 404 (not found) if there is an error
      @cs = ControlSystem.find!(params[:id]?)
    end
  end
end
