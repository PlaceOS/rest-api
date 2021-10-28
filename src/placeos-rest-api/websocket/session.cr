require "hound-dog"
require "mutex"
require "placeos-driver/proxy/remote_driver"
require "tasker"

require "../error"
require "../utilities/params"

module PlaceOS::Api::WebSocket
  class Session
    Log = ::Log.for(self)

    # Class level subscriptions to modules
    class_getter subscriptions : Driver::Proxy::Subscriptions = Driver::Proxy::Subscriptions.new

    # Local subscriptions
    private getter bindings = {} of String => Driver::Subscriptions::Subscription

    # Caching
    private getter cache_lock = Mutex.new
    private getter cache_timeout : Time::Span = 10.minutes

    # Background task to clear module metadata caches
    private getter cache_cleaner : Tasker::Task?

    private getter metadata_cache = {} of String => Driver::DriverModel::Metadata
    private getter module_id_cache = {} of String => String

    private getter write_channel = Channel(String).new

    private getter ws : HTTP::WebSocket

    def initialize(
      @ws : HTTP::WebSocket,
      @request_id : String,
      @user : Model::UserJWT,
      @discovery : HoundDog::Discovery = HoundDog::Discovery.new(CORE_NAMESPACE)
    )
      # Register event handlers
      ws.on_message do |message|
        Log.trace { {frame: "TEXT", text: message} }
        spawn(same_thread: true) do
          on_message(message)
        end
      end

      ws.on_ping do
        Log.trace { {frame: "PING"} }
        ws.pong
      end

      @security_level = if @user.is_admin?
                          Driver::Proxy::RemoteDriver::Clearance::Admin
                        elsif @user.is_support?
                          Driver::Proxy::RemoteDriver::Clearance::Support
                        else
                          Driver::Proxy::RemoteDriver::Clearance::User
                        end

      # Perform writes
      spawn(name: "socket_writes_#{request_id}", same_thread: true) { run_writes }
      # Begin clearing cache
      spawn(name: "cache_cleaner_#{request_id}", same_thread: true) { cache_plumbing }
    end

    # WebSocket API Handlers
    ##############################################################################

    # Grab core url for the module and dial an exec request
    #
    def exec(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String,
      args : Array(JSON::Any)?
    )
      args = [] of JSON::Any if args.nil?
      Log.debug { {message: "exec", args: args.to_json} }

      driver = Driver::Proxy::RemoteDriver.new(
        sys_id: system_id,
        module_name: module_name,
        index: index,
        discovery: @discovery
      )

      response = driver.exec(@security_level, name, args, request_id: @request_id)

      respond(Response.new(
        id: request_id,
        type: :success,
        metadata: {
          sys:   system_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
        value: response,
      ))
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      Log.error(exception: e) { {
        message: "failed to execute request",
        error:   e.message,
      } }
      respond(error_response(request_id, :unexpected_failure, "failed to execute request"))
    end

    # Bind a websocket to a module subscription
    #
    def bind(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      Log.debug { "binding to module" }
      begin
        # Check if module previously bound
        unless has_binding?(system_id, module_name, index, name)
          return unless create_binding(request_id, system_id, module_name, index, name)
        end
      rescue error
        Log.warn(exception: error) { "websocket binding could not find system" }
        respond(error_response(request_id, :module_not_found, "could not find module: sys=#{system_id} mod=#{module_name}"))
        return
      end

      # Notify success
      # TODO: Ensure delivery of success before messages
      #       - keep a flag in @bindings hash, set flag once success sent and send message on channel
      #       - notify update gets subscription, checks binding hash for flag, otherwise wait on channel
      # Could use a promise
      response = Response.new(
        id: request_id,
        type: :success,
        metadata: {
          sys:   system_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
      )
      respond(response)
    rescue e
      Log.error(exception: e) { {
        message: "failed to bind",
        error:   e.message,
      } }
      respond(error_response(request_id, :unexpected_failure, "failed to bind"))
    end

    # Unbind a websocket from a module subscription
    #
    def unbind(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      Log.debug { "unbind module" }

      subscription = delete_binding(system_id, module_name, index, name)
      self.class.subscriptions.unsubscribe(subscription) if subscription

      respond(Response.new(id: request_id, type: :success))
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      Log.error(exception: e) { {
        message: "failed to unbind",
        error:   e.message,
      } }
      respond(error_response(request_id, :unexpected_failure, "failed to unbind"))
    end

    private getter debug_sessions = {} of {String, String, Int32} => HTTP::WebSocket

    # Attach websocket to debug output of a module
    #
    def debug(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      # NOTE: In the interest of saving a redis lookup, the frontend passes
      #       the module_id, rather than name.
      existing_socket = debug_sessions[{system_id, module_name, index}]?

      if !existing_socket || existing_socket.closed?
        driver = Driver::Proxy::RemoteDriver.new(
          module_id: module_name,
          sys_id: system_id,
          module_name: module_name,
          discovery: @discovery
        )

        ws = driver.debug
        ws.on_message do |message|
          begin
            level_value, message = Tuple(Int32, String).from_json(message)
            level = ::Log::Severity.from_value(level_value)

            respond(
              Response.new(
                id: request_id,
                type: :debug,
                module_id: module_name,
                level: level,
                message: message,
                metadata: {
                  sys:   system_id,
                  mod:   module_name,
                  index: index,
                  name:  name,
                },
              ))
          rescue e
            Log.warn(exception: e) { "failed to forward debug message" }
          end
        end

        spawn(same_thread: true) { ws.run }
        debug_sessions[{system_id, module_name, index}] = ws
      else
        Log.trace { "reusing existing debug socket" }
      end

      respond(Response.new(id: request_id, type: :success))
    rescue e
      Log.error(exception: e) { "failed to attach debugger" }
      respond(error_response(request_id, :unexpected_failure, "failed to attach debugger"))
    end

    # Detach websocket from module debug output
    #
    def ignore(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      socket = debug_sessions.delete({system_id, module_name, index})
      # Close the socket if it was present
      socket.try(&.close)
      respond(Response.new(id: request_id, type: :success))
    rescue e
      Log.error(exception: e) { "failed to detach debugger" }
      respond(error_response(request_id, :unexpected_failure, "failed to detach debugger"))
    end

    ##############################################################################

    # Looks up the metadata.
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    #
    def metadata?(system_id, module_name, index) : Driver::DriverModel::Metadata?
      key = Session.cache_key(system_id, module_name, index)
      # Try for value in the cache
      cached = cache_lock.synchronize { metadata_cache[key]? }
      return cached if cached

      # Look up value, refresh cache if value found
      if (module_id = module_id?(system_id, module_name, index))
        Driver::Proxy::System.driver_metadata?(module_id).tap do |meta|
          cache_lock.synchronize { metadata_cache[key] = meta } if meta
        end
      end
    end

    # Looks up the module_id
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    #
    def module_id?(system_id, module_name, index) : String?
      key = Session.cache_key(system_id, module_name, index)
      # Try for value in the cache
      cached = cache_lock.synchronize { module_id_cache[key]? }
      return cached if cached

      # Look up value, refresh cache if value found
      Driver::Proxy::System.module_id?(system_id, module_name, index).tap do |id|
        cache_lock.synchronize { module_id_cache[key] = id } if id
      end
    end

    # Check for existing binding to a module
    #
    def has_binding?(system_id, module_name, index, name)
      bindings.has_key? Session.binding_key(system_id, module_name, index, name)
    end

    # Create a binding to a module on the Session
    #
    protected def create_binding(request_id, system_id, module_name, index, name) : Bool
      key = Session.binding_key(system_id, module_name, index, name)

      if module_name.starts_with?("_") && !@user.is_support?
        Log.warn { "websocket binding attempted to access privileged module" }
        respond error_response(request_id, :access_denied, "attempted to access protected module")
        return false
      end

      if module_name == "_TRIGGER_"
        # Ensure the trigger exists
        trig = Model::TriggerInstance.find(name)
        unless trig.try(&.control_system_id) == system_id
          Log.warn { {message: "websocket binding attempted to access unknown trigger", trigger_instance_id: name} }
          respond error_response(request_id, :module_not_found, "no trigger instance #{name} in system #{system_id}")
          return false
        end

        # Triggers should be subscribed to directly.
        bindings[key] = self.class.subscriptions.subscribe(name, "state") do |_, event|
          notify_update(
            request_id: request_id,
            system_id: system_id,
            module_name: module_name,
            status: name,
            index: index,
            value: event
          )
        end
      else
        # Subscribe and set local binding
        bindings[key] = self.class.subscriptions.subscribe(system_id, module_name, index, name) do |_, event|
          notify_update(
            request_id: request_id,
            system_id: system_id,
            module_name: module_name,
            status: name,
            index: index,
            value: event
          )
        end
      end

      true
    end

    # Create a binding to a module on the Session
    #
    def delete_binding(system_id, module_name, index, name)
      key = Session.binding_key(system_id, module_name, index, name)
      bindings.delete key
    end

    # Event handlers
    ###########################################################################

    # Parse an update from a subscription and pass to listener
    #
    def notify_update(value, request_id, system_id, module_name, index, status)
      respond(Response.new(
        id: request_id,
        type: :notify,
        value: value,
        metadata: {
          sys:   system_id,
          mod:   module_name,
          index: index,
          name:  status,
        }
      ))
    end

    protected def write(data)
      write_channel.send(data)
    end

    # Request handler
    #
    protected def on_message(data)
      return write("pong") if data == "ping"

      # Execute the request
      request = parse_request(data)
      handle_request(request) if request
    rescue e
      Log.error(exception: e) { {message: "websocket request failed", data: data} }
      response = error_response(request.try(&.id), :request_failed, e.message)
      respond(response)
    end

    # Shutdown handler
    #
    def cleanup
      # Stop the cache cleaner
      cache_cleaner.try &.cancel

      # Unbind all modules
      bindings.clear

      # Ignore (stop debugging) all modules
      debug_sessions.each_value &.close
      debug_sessions.clear
    end

    # Utilities
    ###########################################################################

    # Index into module websocket sessions
    def self.binding_key(system_id, module_name, index, name)
      {system_id, module_name, index, name}.join('_')
    end

    # Index into module_id cache
    def self.cache_key(system_id, module_name, index)
      {system_id, module_name, index}.join('_')
    end

    # Headers for requesting engine core,
    # - forwards request id for tracing
    protected def default_headers
      HTTP::Headers{
        "X-Request-ID" => @request_id,
        "Content-Type" => "application/json",
      }
    end

    # Ensures
    # - required params present
    # - command recognised
    def parse_request(data) : Request?
      Request.from_json(data)
    rescue e
      id = (NamedTuple(id: Int64?).from_json(data) rescue nil).try &.[:id]
      Log.warn { {message: "failed to parse", data: data, id: id} }
      error_response(id, :bad_request, "bad request: #{e.message}")
      nil
    end

    protected def error_response(
      request_id : Int64?,
      error_code : Response::ErrorCode?,
      message : String?
    )
      Api::WebSocket::Session::Response.new(
        id: request_id || 0_i64,
        type: :error,
        error_code: error_code,
        message: message || "",
      )
    end

    # Empty's metadata cache upon cache_timeout
    #
    protected def cache_plumbing
      @cache_cleaner = Tasker.instance.every(cache_timeout) do
        Log.trace { "cleaning websocket session cache" }
        cache_lock.synchronize do
          @metadata_cache = {} of String => Driver::DriverModel::Metadata
          @module_id_cache = {} of String => String
        end
      end
    end

    private def run_writes
      while data = write_channel.receive?
        ws.send(data)
      end
    end

    protected def respond(response : Response)
      return if ws.closed?
      write(response.to_json)
    end

    # Delegate request to correct handler
    #
    protected def handle_request(request : Request)
      arguments = {
        request_id:  request.id,
        system_id:   request.system_id,
        module_name: request.module_name,
        index:       request.index,
        name:        request.name,
      }
      Log.context.set(**arguments.merge({ws_request_id: @request_id}))

      case request.command
      in .bind?   then bind(**arguments)
      in .unbind? then unbind(**arguments)
      in .debug?  then debug(**arguments)
      in .ignore? then ignore(**arguments)
      in .exec?   then exec(**arguments, args: request.args)
      end
    end
  end
end

require "./session/request"
require "./session/response"
