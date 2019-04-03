class Modules < Application
  before_action :check_admin, except: [:index, :state, :show, :ping]
  before_action :check_support, only: [:index, :state, :show, :ping]
  before_action :find_module, only: [:show, :update, :destroy, :ping]

  # Constant for performance
  MOD_INCLUDE = {
    include: {
      # Provide the server information
      edge: {only: [:name, :description]},

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

  def index
    filters = params.select("system_id", "dependency_id", "connected", "no_logic", "running", "as_of")

    # if a system id is present we query the database directly
    if filters.has_key? "system_id"
      cs = ControlSystem.find(filters["system_id"])

      results = Module.find_all(cs.modules).to_a
      render json: {
        total:   results.length,
        results: results,
      }
    else # we use elastic search
      query = Module.elastic.query(params)

      if filters.has_key? "dependency_id"
        query.filter({"doc.dependency_id" => [filters["dependency_id"]]})
      end

      if filters.has_key? "connected"
        connected = filters["connected"] == "true"

        query.filter({"doc.ignore_connected" => [false]})
        query.filter({"doc.connected" => [connected]})

        unless connected
          query.should([{term: {"doc.ignore_connected" => false}},
                        {missing: {field: "doc.ignore_connected"}}])
        end
      end

      if filters.has_key? "running"
        running = filters["running"] == "true"
        query.filter({"doc.running" => [running]})
      end

      if filters.has_key? "no_logic"
        query.filter({"doc.role" => [0, 1, 2]})
      end

      if filters.has_key? "as_of"
        query.filter({
          range: {
            "doc.updated_at" => {
              lte: filters[:as_of].to_i,
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

  # TODO: This depends on extended save_and_respond function
  # def update
  #     para = safe_params
  #     @mod.assign_attributes(para)
  #     was_running = @mod.running

  #     save_and_respond(@mod, include: {
  #         dependency: {
  #             only: [:name, :module_name]
  #         }
  #     }) do
  #         # Update the running module
  #         promise = control.update(id)
  #         if was_running
  #             promise.finally do
  #                 control.start(id)
  #             end
  #         end
  #     end
  # end

  def create
    mod = Module.new(safe_params)
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

  # # Dumps internal state out of the logger at debug level
  # # and returns the internal state
  # def internal_state
  #     lookup_module do |mod|
  #         defer = reactor.defer
  #         mod.thread.next_tick do
  #             begin
  #                 defer.resolve(mod.instance.__STATS__)
  #             rescue => err
  #                 defer.reject(err)
  #             end
  #         end
  #         render body: defer.promise.value.inspect
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

  protected MOD_PARAMS = [
    :dependency_id, :control_system_id, :edge_id,
    :ip, :tls, :udp, :port, :makebreak, :uri,
    :custom_name, :notes, :ignore_connected,
    :ignore_startstop,
  ]

  protected def safe_params
    settings = params[:settings]
    args = params.permit(MOD_PARAMS).to_h
    args[:settings] = settings.to_unsafe_hash if settings
    args
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
