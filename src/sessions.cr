require "logger"
require "tasker"

# Hack around abstract base class for driver applications
class EngineDriver; end

require "redis"
require "engine-driver/subscriptions"
require "engine-driver/proxy/subscriptions"

require "./utilities/params"

module Engine::API
  # Stores sessions until their websocket closes
  class SessionManager
    @sessions = [] of Session

    def initialize(@logger = Logger.new)
    end

    # Creates the session and handles the cleanup
    #
    def create_session(ws, request_id, user)
      session = Session.new(
        ws: ws,
        request_id: request_id,
        user: user,
        logger: @logger
      )

      ws.on_close do |_|
        session.cleanup
        @sessions.delete(session)
      end
    end
  end

  class Session
    COMMANDS = %w(exec bind unbind debug ignore)

    @@subscriptions = EngineDriver::Proxy::Subscriptions.new

    # Local subscriptions
    @bindings : Hash(String, EngineDriver::Subscriptions::Subscription) = {} of String => EngineDriver::Subscriptions::Subscription

    @cache_cleaner : Tasker::Task?

    def initialize(
      @ws : HTTP::WebSocket,
      @request_id : String,
      @user : Engine::Model::UserJWT,
      @logger : Logger = Logger.new,
      @cache_timeout : Int32 = 60 * 5
    )
      # Register event handlers
      @ws.on_message(&->on_message(String))
      @ws.on_ping { |_| @ws.pong }

      # NOTE: Might need a rw-lock/concurrent-map due to cache cleaning fiber
      @metadata_cache = {} of String => EngineDriver::DriverModel::Metadata
      @module_id_cache = {} of String => String

      # Begin clearing cache
      spawn name: "cache_cleaner" { cache_plumbing }
    end

    # Grab metatadata from driver proxy
    # - check function in system
    # - check for presence of function in security against current security level
    # - consistent hash of module_id to determine core
    # - make exec request to correct core
    #
    def exec(
      id : String,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String,
      args : Array(JSON::Any)
    )
      unless (metadata = metadata?(sys_id, module_name, index))
        @logger.debug("websocket exec could not find module: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
        error_response(id, ErrorCode::ModuleNotFound, "could not find module: mod=#{module_name}")
        return
      end

      unless function_present?(metadata.functions, name)
        @logger.debug("websocket exec could not find function: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
        error_response(id, ErrorCode::BadRequest, "could not find function: name=#{name}")
        return
      end

      unless function_visible?(metadata.security, name)
        @logger.warn("websocket exec attempted to access priviled function: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
        error_response(id, ErrorCode::AccessDenied, "attempted to access privileged function")
        return
      end

      # TODO: Make request to core
      # - Locate core responsible for module through consistent hashing
      # - Make request to core
      # - Respond with result

      unless (module_id = module_id?(sys_id, module_name, index))
        @logger.warn("websocket exec could not find module id: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
        error_response(id, ErrorCode::RequestFailed, "failed to locate module: mod=#{module_name}")
        return
      end

      core_url = locate_module?(module_id)
      unless core_url
        @logger.warn("websocket exec could not locate module's system: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
        error_response(id, ErrorCode::RequestFailed, "failed to locate module: mod=#{module_name}")
        return
      end

      response = HTTP::Client.post(core_url)
      if response.success?
        @ws.send({
          id:    id,
          type:  :success,
          value: response.body,
        }.to_json)
      else
        @logger.warn("websocket exec failed: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
        error_response(id, ErrorCode::RequestFailed, response.body)
      end
    end

    # Bind a websocket to a module subscription
    #
    def bind(
      id : String,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      lookup = "#{sys_id}_#{module_name}_#{index}_#{name}"
      begin
        # Check if module previously bound
        unless @bindings.has_key? lookup
          # Subscribe and set local binding
          @bindings[lookup] = @@subscriptions.subscribe(sys_id, module_name, index, lookup) do |_, event|
            notify_update(event)
          end
        end
      rescue
        @logger.debug("websocket binding could not find system: {sys: #{sys_id}, mod: #{module_name}, index: #{index}, name: #{name}}")
        error_response(id, ErrorCode::ModuleNotFound, "could not find module: sys=#{sys_id} mod=#{module_name}")
      end

      # Notify success
      # TODO: Ensure delivery of success before messages
      #       - keep a flag in @bindings hash, set flag once success sent and send message on channel
      #       - notify update gets subscription, checks binding hash for flag, otherwise wait on channel
      # Could use a promise
      @ws.send({
        id:   id,
        type: :success,
        meta: {
          sys:   sys_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
      }.to_json)
    end

    # Unbind a websocket from a module subscription
    #
    def unbind(
      id : String,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      lookup = "#{sys_id}_#{module_name}_#{index}_#{name}"
      subscription = @bindings.delete(lookup)

      @subscriptions.unsubscribe(subscription) if subscription

      @ws.send({
        id:   id,
        type: :success,
      }.to_json)
    end

    def debug
      raise "debug unimplemented"
    end

    def ignore
      raise "ignore unimplemented"
    end

    # Looks up the metadata.
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    def metadata?(sys_id, module_name, index) : EngineDriver::DriverModel::Metadata?
      key = Session.cache_key(sys_id, module_name, index)
      # Try for value in the cache
      cached = @metadata_cache[key]?
      return cached if cached

      # Look up value, refresh cache if value found
      if (module_id = module_id?(sys_id, module_name, index))
        EngineDriver::Proxy::System.driver_metadata?(module_id).tap do |metadata|
          @metadata_cache[key] = metadata if metadata
        end
      end
    end

    # Looks up the module_id
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    def module_id?(sys_id, module_name, index) : String?
      key = Session.cache_key(sys_id, module_name, index)
      # Try for value in the cache
      cached = @module_id_cache[key]?
      return cached if cached

      # Look up value, refresh cache if value found
      EngineDriver::Proxy::System.module_id?(sys_id, module_name, index).tap do |id|
        @module_id_cache[key] = id if id
      end
    end

    def self.cache_key(sys_id, module_name, index)
      "#{sys_id}_#{module_name}_#{index}"
    end

    # Determine if function visible to user
    #
    def function_present?(functions, function)
      functions.keys.includes?(function)
    end

    # Determine if user has access to function
    #
    def function_visible?(security, function)
      # Find the access control level containing the function, if any.
      access_control = security.find do |_, functions|
        functions.includes? function
      end

      # No access control on the function... general access.
      return true unless access_control

      level, _ = access_control

      # Check user's privilege against the function's privilege.
      case level
      when "support"
        @user.is_support?
      when "administrator"
        @user.is_admin?
      else
        false
      end
    end

    # TODO: Consistent hash lookup of module id to core address
    def locate_module?(module_id : String) : URI?
      puts "noop"
      URI.parse("https://core_1")
    end

    # Message handlers
    ###########################################################################

    # Message from a subscription
    #
    class Update
      include JSON::Serializable

      property sys_id : String
      property mod_name : String
      property index : Int32
      property status : String

      property value : JSON::Any
    end

    # Parse an update from a subscription and pass to listener
    #
    def notify_update(message)
      update = Update.from_json(message)
      @ws.send({
        type:  :notify,
        value: update.value,
        meta:  {
          sys:   update.sys_id,
          mod:   update.mod_name,
          index: update.index,
          name:  update.status,
        },
      }.to_json)
    end

    # Request handler
    #
    protected def on_message(data)
      # Execute the request
      if (message = unmarshall_message(data))
        __send__(message)
      end
    rescue e
      @logger.error(e, "websocket request failed: data=#{data} message=#{message} error=#{e.inspect_with_backtrace}")
      error_response(message.try(&.id), ErrorCode::RequestFailed, e.message)
    end

    # Shutdown handler
    #
    def cleanup
      # Stop the cache cleaner
      @cache_cleaner.try &.cancel

      # Unbind all modules
      @bindings.clear

      # TODO: Ignore (stop debugging) all modules
    end

    # Utilities
    ###########################################################################

    # Headers for requesting engine core,
    # - forwards request id for tracing
    protected def default_headers
      HTTP::Headers{
        "X-Request-ID" => @request_id,
        "Content-Type" => "application/json",
      }
    end

    # A websocket API request
    class WebsocketMessage
      include JSON::Serializable
      include JSON::Serializable::Strict

      property id : String

      # Module location metadata
      @[JSON::Field(key: "sys")]
      property sys_id : String

      @[JSON::Field(key: "mod")]
      property module_name : String

      property index : Int32 = 1

      # Command
      @[JSON::Field(key: "cmd")]
      property command : String

      # Function name
      property name : String

      # Function arguments
      @[JSON::Field(emit_null: true)]
      property args : Array(JSON::Any)
    end

    @[Flags]
    enum ErrorCode
      ParseError     # 0
      BadRequest     # 1
      AccessDenied   # 2
      RequestFailed  # 3
      UnknownCommand # 4

      SystemNotFound    # 5
      ModuleNotFound    # 6
      UnexpectedFailure # 7
      def to_s
        super.underscore
      end
    end

    def error_response(id : String?, error : ErrorCode, message : String?)
      response = {
        id:   id || "",
        type: :error,
        code: error.to_i,
        msg:  message || "",
      }
      @ws.send(response.to_json)
    end

    # Ensure
    # - required params present
    # - command recognised
    def unmarshall_message(data) : WebsocketMessage?
      return unless (message = parse_message(data))

      unless COMMANDS.includes?(message.command)
        @logger.warn("websocket requested unknown command: cmd=#{message.command}")
        error_response(message.id, ErrorCode::UnknownCommand, "unknown command: #{message.command}")
        return
      end

      message
    end

    def parse_message(data) : WebsocketMessage?
      WebsocketMessage.from_json(data)
    rescue e
      @logger.warn("failed to parse: data=#{data}")
      error_response(nil, ErrorCode::BadRequest, "required parameters missing from request")
      return
    end

    # Empty's metadata cache upon cache_timeout
    #
    protected def cache_plumbing
      @cache_cleaner = Tasker.instance.every(@cache_timeout.seconds) do
        @metadata_cache.clear
        @module_id_cache.clear
      end
    end

    # Delegate message to correct handler
    #
    protected def __send__(message : WebsocketMessage)
      case message.command
      when "exec"
        exec(
          id: message.id,
          sys_id: message.sys_id,
          module_name: message.module_name,
          index: message.index,
          name: message.name,
          args: message.args,
        )
      when "bind"
        bind(
          id: message.id,
          sys_id: message.sys_id,
          module_name: message.module_name,
          index: message.index,
          name: message.name,
        )
      when "unbind"
        bind(
          id: message.id,
          sys_id: message.sys_id,
          module_name: message.module_name,
          index: message.index,
          name: message.name,
        )
      when "debug"
        debug
      when "ignore"
        ignore
      else
        @logger.error("unrecognised websocket command: cmd=#{message.command}")
      end
    end
  end
end
