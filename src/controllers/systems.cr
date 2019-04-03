class ControlSystems < Application
  base "/api/systems/"

  # state, funcs, count and types are available to authenticated users
  before_action :check_admin, only: [:create, :update, :destroy, :remove, :start, :stop]
  before_action :find_system, only: [:show, :update, :destroy, :remove, :count, :start, :stop]

  @cs : ControlSystem?

  # Query control system resources
  def index
    query = System.elastic.query(params)
    query.sort = NAME_SORT_ASC

    # Filter systems via zone_id
    if params.has_key? :zone_id
      zone_id = params.permit(:zone_id)[:zone_id]
      query.filter({
        "doc.zones" => [zone_id],
      })
    end

    # filter via module_id
    if params.has_key? :module_id
      module_id = params.permit(:module_id)[:module_id]
      query.filter({
        "doc.modules" => [module_id],
      })
    end

    query.search_field "doc.name"
    render json: System.elastic.search(query)
  end

  SYS_INCLUDE = {
    include: {edge: {only: [:name, :description]}},
    methods: [:module_data, :zone_data],
  }

  # Renders a control system
  def show
    if params.has_key? :complete
      render json: @cs.as_json(SYS_INCLUDE)
    else
      render json: @cs
    end
  end

  # Updates a control system
  def update
    args = safe_params
    return head(:conflict) if args[:version].to_i != @cs.version
    @cs.assign_attributes(safe_params)
    @cs.version += 1
    save_and_respond(@cs)
  end

  # Removes the module from the system and deletes it if not used elsewhere
  def remove
    # module_id = params.permit(:module_id)[:module_id]
    module_id = params[:module_id]?
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
    cs = ControlSystem.new(safe_params)
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
  # def start
  #   loaded = [] of Module
  #
  #   # Start all modules in the system
  #   @cs.modules.each do |mod_id|
  #     promise = control.start(mod_id, system_level: true)
  #     loaded << promise
  #   end

  #   # This needs to be done on the remote as well
  #   # Clear the system cache once the modules are loaded
  #   # This ensures the cache is accurate
  #   control.reactor.finally(*loaded).then {
  #     # Might as well trigger update behaviour.
  #     # Ensures logic modules that interact with other logic modules
  #     # are accurately informed
  #     control.expire_cache(@cs.id)
  #   }.value

  #   head :ok
  # end

  # def stop
  #   # Stop all modules in the system (shared or not)
  #   @cs.modules.each do |mod_id|
  #     control.stop(mod_id, system_level: true)
  #   end
  #   head :ok
  # end

  # EXEC_PARAMS = [:module, :index, :method]
  # def exec
  #     # Run a function in a system module (async request)
  #     params.require(:module)
  #     params.require(:method)

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
  #   params.require(:module)
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
  #       params.require(:module)
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

  # return the count of a module type in a system
  def count
    params.require(:module)

    id = params["id"]
    sys = System.find(id)
    if sys
      mod = params[:module]
      render json: {count: sys.count(mod)}
    else
      head :not_found
    end
  end

  # returns a hash of a module types in a system with
  # the count of each of those types
  def types
    id = params["id"]
    sys = System.find(id)
    if sys
      mods = sys.modules
      # mods.delete(:__Triggers__)
      result = mods.each_with_object({} of String => Int32) do |mod, counts|
        counts[mod] = sys.count(mod)
      end
      render json: result
    else
      head :not_found
    end
  end

  # Better performance as don't need to create the object each time
  protected CS_PARAMS = [
    :name, :edge_id, :description, :support_url, :installed_ui_devices,
    :capacity, :email, :bookable, :features, :version,
    {
      zones:   [] of String,
      modules: [] of String,
    },
  ]

  # We need to support an arbitrary settings hash so have to
  # work around safe params as per
  # http://guides.rubyonrails.org/action_controller_overview.html#outside-the-scope-of-strong-parameters
  protected def safe_params
    settings = params[:settings]
    args = params.permit(CS_PARAMS).to_h
    args[:settings] = settings.to_unsafe_hash if settings
    args[:installed_ui_devices] = args[:installed_ui_devices].to_i if args.has_key? :installed_ui_devices
    args[:capacity] = args[:capacity].to_i if args.has_key? :capacity
    args
  end

  protected def find_system
    # Find will raise a 404 (not found) if there is an error
    @cs = ControlSystem.find!(params[:id]?)
  end
end
