# FIXME: Hack to allow resolution of ACAEngine::Driver class/module
module ACAEngine; end

class ACAEngine::Driver; end

require "action-controller/logger"
require "engine-driver/proxy/remote_driver"
require "hound-dog"
require "redis"
require "tasker"

require "./error"
require "./utilities/params"

module ACAEngine
  class Api::Session
    # Stores sessions until their websocket closes
    class Manager
      @sessions = [] of Session

      def initialize(
        @discovery : HoundDog::Discovery
      )
      end

      # Creates the session and handles the cleanup
      #
      def create_session(ws, request_id, user, logger)
        session = Session.new(
          ws: ws,
          request_id: request_id,
          user: user,
          discovery: @discovery,
          logger: logger,
        )

        @sessions << session

        ws.on_close do |_|
          logger.debug { "Session CLOSE" }
          session.cleanup
          @sessions.delete(session)
        end
      end
    end

    # Class level subscriptions to modules
    @@subscriptions = Driver::Proxy::Subscriptions.new

    # Local subscriptions
    @bindings = {} of String => Driver::Subscriptions::Subscription

    # Background task to clear module metadata caches
    @cache_cleaner : Tasker::Task?

    getter ws : HTTP::WebSocket

    def initialize(
      @ws : HTTP::WebSocket,
      @request_id : String,
      @user : Model::UserJWT,
      @discovery : HoundDog::Discovery = HoundDog::Discovery.new(CORE_NAMESPACE),
      @logger : ActionController::Logger::TaggedLogger = ActionController::Logger::TaggedLogger.new(ActionController::Base.settings.logger),
      @cache_timeout : Int32? = 60 * 5
    )
      # Register event handlers
      @ws.on_message do |message|
        @logger.debug { "Session TEXT (#{message})" }
        on_message(message)
      end

      @ws.on_ping do
        @logger.debug { "Session PING" }
        @ws.pong
      end

      # NOTE: Might need a rw-lock/concurrent-map due to cache cleaning fiber
      @metadata_cache = {} of String => Driver::DriverModel::Metadata
      @module_id_cache = {} of String => String

      @security_level = if @user.is_admin?
                          Driver::Proxy::RemoteDriver::Clearance::Admin
                        elsif @user.is_support?
                          Driver::Proxy::RemoteDriver::Clearance::Support
                        else
                          Driver::Proxy::RemoteDriver::Clearance::User
                        end

      # Begin clearing cache
      spawn(name: "cache_cleaner", same_thread: true) { cache_plumbing }
    end

    # Websocket API
    ##############################################################################

    # A websocket API request
    class Request
      include JSON::Serializable
      include JSON::Serializable::Strict

      # Commands available over websocket API
      enum Command
        Exec
        Bind
        Unbind
        Debug
        Ignore
      end

      def initialize(
        @id,
        @sys_id,
        @module_name,
        @command,
        @name,
        @index = 1,
        @args = nil
      )
      end

      property id : Int64

      # Module location metadata
      @[JSON::Field(key: "sys")]
      property sys_id : String

      @[JSON::Field(key: "mod")]
      property module_name : String

      property index : Int32 = 1

      # Command
      @[JSON::Field(key: "cmd")]
      property command : Command

      # Function name
      property name : String

      # Function arguments
      @[JSON::Field(emit_null: true)]
      property args : Array(JSON::Any)?
    end

    alias ErrorCode = Driver::Proxy::RemoteDriver::ErrorCode

    # Websocket API Response
    struct Response
      include JSON::Serializable
      property id : Int64
      property type : Type

      property error_code : Int32?

      @[JSON::Field(key: "msg")]
      property message : String?

      property value : String?
      property meta : Metadata?

      @[JSON::Field(key: "mod")]
      property module_id : String?

      @[JSON::Field(converter: SeverityConverter)]
      property level : Logger::Severity?

      alias Metadata = NamedTuple(
        sys: String,
        mod: String,
        index: Int32,
        name: String,
      )

      def initialize(
        @id : Int64,
        @type,
        @error_code = nil,
        @message = nil,
        @value = nil,
        @module_id = nil,
        @meta = nil
      )
      end

      # Response type
      enum Type
        Success
        Notify
        Error
        Debug

        def to_json(json)
          json.string(to_s.downcase)
        end
      end
    end

    # Grab core url for the module and dial an exec request
    #
    def exec(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String,
      args : Array(JSON::Any)
    )
      @logger.tag_debug(
        message: "Session (exec)",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
        args: args
      )

      driver = Driver::Proxy::RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index
      )

      response = driver.exec(@security_level, name, args, request_id: @request_id)

      respond(Response.new(
        id: request_id,
        type: Response::Type::Success,
        meta: {
          sys:   sys_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
        value: "%{}",
      ), response)
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      @logger.tag_error(
        message: "failed to execute request",
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
        error: e.message
      )
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to execute request"))
    end

    # Bind a websocket to a module subscription
    #
    def bind(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      @logger.tag_debug(
        message: "Session (bind)",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
      )
      begin
        # Check if module previously bound
        unless has_binding?(sys_id, module_name, index, name)
          return unless create_binding(request_id, sys_id, module_name, index, name)
        end
      rescue
        @logger.tag_debug("websocket binding could not find system", sys_id: sys_id, module_name: module_name, index: index, name: name)
        respond(error_response(request_id, ErrorCode::ModuleNotFound, "could not find module: sys=#{sys_id} mod=#{module_name}"))
        return
      end

      # Notify success
      # TODO: Ensure delivery of success before messages
      #       - keep a flag in @bindings hash, set flag once success sent and send message on channel
      #       - notify update gets subscription, checks binding hash for flag, otherwise wait on channel
      # Could use a promise
      response = Response.new(
        id: request_id,
        type: Response::Type::Success,
        meta: {
          sys:   sys_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
      )
      respond(response)
    rescue e
      @logger.tag_error(
        message: "failed to bind",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
        error: e.message
      )
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to bind"))
    end

    # Unbind a websocket from a module subscription
    #
    def unbind(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      @logger.tag_debug(
        message: "Session (unbind)",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
      )

      subscription = delete_binding(sys_id, module_name, index, name)
      @@subscriptions.unsubscribe(subscription) if subscription

      respond(Response.new(id: request_id, type: Response::Type::Success))
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      @logger.tag_error(
        message: "failed to unbind",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
        error: e.message
      )
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to unbind"))
    end

    private getter debug_sessions = {} of {String, String, Int32} => HTTP::WebSocket

    def debug(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      existing_socket = debug_sessions[{sys_id, module_name, index}]?

      if (!existing_socket) || (existing_socket && existing_socket.closed?)
        driver = Driver::Proxy::RemoteDriver.new(
          sys_id: sys_id,
          module_name: module_name,
          index: index
        )

        module_id = driver.module_id?

        ws = driver.debug
        ws.on_message do |message|
          respond(
            Response.new(
              id: request_id,
              module_id: module_id,
              type: Response::Type::Debug,
              message: message,
              meta: {
                sys:   sys_id,
                mod:   module_name,
                index: index,
                name:  name,
              },
            ))
        end

        spawn ws.run
        debug_sessions[{sys_id, module_name, index}] = ws
      end

      respond(Response.new(id: request_id, type: Response::Type::Success))
    rescue e
      @logger.tag_error(
        message: "failed to attach debugger",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
        error: e.message
      )
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to attach debugger"))
    end

    def ignore(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      debug_sessions.delete({sys_id, module_name, index})
      respond(Response.new(id: request_id, type: Response::Type::Success))
    rescue e
      @logger.tag_error(
        message: "failed to detach debugger",
        ws_request_id: request_id,
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        name: name,
        error: e.message
      )
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to detach debugger"))
    end

    ##############################################################################

    # Looks up the metadata.
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    #
    def metadata?(sys_id, module_name, index) : Driver::DriverModel::Metadata?
      key = Session.cache_key(sys_id, module_name, index)
      # Try for value in the cache
      cached = @metadata_cache[key]?
      return cached if cached

      # Look up value, refresh cache if value found
      if (module_id = module_id?(sys_id, module_name, index))
        Driver::Proxy::System.driver_metadata?(module_id).tap do |metadata|
          @metadata_cache[key] = metadata if metadata
        end
      end
    end

    # Looks up the module_id
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    #
    def module_id?(sys_id, module_name, index) : String?
      key = Session.cache_key(sys_id, module_name, index)
      # Try for value in the cache
      cached = @module_id_cache[key]?
      return cached if cached

      # Look up value, refresh cache if value found
      Driver::Proxy::System.module_id?(sys_id, module_name, index).tap do |id|
        @module_id_cache[key] = id if id
      end
    end

    # Check for existing binding to a module
    #
    def has_binding?(sys_id, module_name, index, name)
      @bindings.has_key? Session.binding_key(sys_id, module_name, index, name)
    end

    alias RedisMessage = NamedTuple(
      request_id: Int64,
      sys_id: String,
      mod_name: String,
      index: Int32,
      status: String,
      value: String,
    )

    # Create a binding to a module on the Session
    #
    def create_binding(request_id, sys_id, module_name, index, name) : Bool
      key = Session.binding_key(sys_id, module_name, index, name)

      if module_name.starts_with?("_") && !@user.is_support?
        @logger.tag_warn("websocket binding attempted to access priviled module", sys_id: sys_id, module_name: module_name, index: index, name: name)
        respond error_response(request_id, ErrorCode::AccessDenied, "attempted to access protected module")
        return false
      end

      if module_name == "_TRIGGER_"
        # Ensure the trigger exists
        trig = Model::TriggerInstance.find(name)
        unless trig && trig.control_system_id == sys_id
          @logger.tag_warn("websocket binding attempted to access unknown trigger", sys_id: sys_id, trig_id: name)
          respond error_response(request_id, ErrorCode::ModuleNotFound, "no trigger #{name} in system #{sys_id}")
          return false
        end

        # Triggers should be subscribed to directly.
        @bindings[key] = @@subscriptions.subscribe(name, "state") do |_, event|
          notify_update(
            request_id: request_id,
            system_id: sys_id,
            module_name: module_name,
            status: name,
            index: index,
            value: event
          )
        end
      else
        # Subscribe and set local binding
        @bindings[key] = @@subscriptions.subscribe(sys_id, module_name, index, name) do |_, event|
          notify_update(
            request_id: request_id,
            system_id: sys_id,
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
    def delete_binding(sys_id, module_name, index, name)
      key = Session.binding_key(sys_id, module_name, index, name)
      @bindings.delete key
    end

    # Event handlers
    ###########################################################################

    # # Message from a subscription
    # #
    # class Update
    #   include JSON::Serializable
    #   property sys_id : String
    #   property mod_name : String
    #   property index : Int32
    #   property status : String
    #   property value : JSON::Any
    # end

    # Parse an update from a subscription and pass to listener
    #
    def notify_update(value, request_id, system_id, module_name, index, status)
      response = Response.new(
        id: request_id,
        type: Response::Type::Notify,
        value: value,
        meta: {
          sys:   system_id,
          mod:   module_name,
          index: index,
          name:  status,
        },
      )
      respond(response)
    end

    # Request handler
    #
    protected def on_message(data)
      return @ws.send("pong") if data == "ping"

      # Execute the request
      request = parse_request(data)
      __send__(request) if request
    rescue e
      @logger.tag_error("websocket request failed", data: data, error: e.inspect_with_backtrace)
      response = error_response(request.try(&.id), ErrorCode::RequestFailed, e.message)
      respond(response)
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

    # Index into module websocket sessions
    def self.binding_key(sys_id, module_name, index, name)
      "#{sys_id}_#{module_name}_#{index}_#{name}"
    end

    # Index into module_id cache
    def self.cache_key(sys_id, module_name, index)
      "#{sys_id}_#{module_name}_#{index}"
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
      @logger.tag_warn("failed to parse", data: data, error: e.message)
      error_response(JSON.parse(data)["id"]?.try &.as_i64, ErrorCode::BadRequest, "bad request: #{e.message}")
      return
    end

    protected def error_response(
      request_id : Int64?,
      error_code,
      message : String?
    )
      Api::Session::Response.new(
        id: request_id || 0_i64,
        type: Api::Session::Response::Type::Error,
        error_code: error_code.to_i,
        message: message || "",
      )
    end

    # Empty's metadata cache upon cache_timeout
    #
    protected def cache_plumbing
      if (timeout = @cache_timeout)
        @cache_cleaner = Tasker.instance.every(timeout.seconds) do
          @metadata_cache.clear
          @module_id_cache.clear
        end
      end
    end

    protected def respond(response : Response, payload = nil)
      return if @ws.closed?

      if payload
        # Avoids parsing and serialising when payload is already in JSON format
        partial = response.to_json
        @ws.send(partial.sub(%("%{}"), payload))
      else
        @ws.send(response.to_json)
      end
    end

    # Delegate request to correct handler
    #
    protected def __send__(request : Request)
      arguments = {
        request_id:  request.id,
        sys_id:      request.sys_id,
        module_name: request.module_name,
        index:       request.index,
        name:        request.name,
      }
      case request.command
      when Request::Command::Bind   then bind(**arguments)
      when Request::Command::Unbind then unbind(**arguments)
      when Request::Command::Debug  then debug(**arguments)
      when Request::Command::Ignore then ignore(**arguments)
      when Request::Command::Exec
        args = request.args.as(Array(JSON::Any))
        exec(**arguments.merge({args: args}))
      else
        @logger.tag_error("unrecognised websocket command", cmd: request.command)
      end
    end
  end
end

# Serialization for severity fields of models
module SeverityConverter
  def self.to_json(value : Logger::Severity, json : JSON::Builder)
    json.string(value.to_s.downcase)
  end

  def self.from_json(value : JSON::PullParser) : Logger::Severity
    Logger::Severity.new(value)
  end
end
