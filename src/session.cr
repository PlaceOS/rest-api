require "logger"
require "tasker"

# Hack around abstract base class for driver applications
class EngineDriver; end

require "redis"
require "engine-driver/subscriptions"
require "engine-driver/proxy/subscriptions"

require "./utilities/params"

class Engine::API::Session
  # Stores sessions until their websocket closes
  class Manager
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

  # Class level subscriptions to modules
  @@subscriptions = EngineDriver::Proxy::Subscriptions.new

  # Local subscriptions
  @bindings = {} of String => EngineDriver::Subscriptions::Subscription

  # Background task to clear module metadata caches
  @cache_cleaner : Tasker::Task?

  def initialize(
    @ws : HTTP::WebSocket,
    @request_id : String,
    @user : Engine::Model::UserJWT,
    @logger : Logger = Engine::API.settings.logger,
    @cache_timeout : Int32? = 60 * 5
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

    property id : String

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

  # Websocket API Response
  struct Response
    include JSON::Serializable

    def initialize(
      @id,
      @type,
      @error_code = nil,
      @error_message = nil,
      @value = nil,
      @meta = nil
    )
    end

    # Request type
    enum Type
      Success
      Notify
      Error

      def to_json(json)
        json.string(to_s.downcase)
      end
    end

    @[JSON::Field(key: "id")]
    property id : String

    property type : Type

    @[JSON::Field(key: "code")]
    property error_code : Int32?
    @[JSON::Field(key: "msg")]
    property error_message : String?

    property value : JSON::Any?
    property meta : Metadata?

    alias Metadata = NamedTuple(
      sys: String,
      mod: String,
      index: Int32,
      name: String,
    )
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

  # Generate an error response
  #
  def error_response(id : String?, error : ErrorCode, message : String?)
    response = Response.new(
      id: id || "",
      type: Response::Type::Error,
      error_code: error.to_i,
      error_message: message || "",
    )
    respond(response)
  end

  # Grab metatadata from driver proxy
  # - check function in system
  # - check for presence of function in security against current security level
  # - consistent hash of module_id to determine core
  # - make exec request to correct core
  #
  def exec(
    request_id : String,
    sys_id : String,
    module_name : String,
    index : Int32,
    name : String,
    args : Array(JSON::Any)
  )
    unless (metadata = metadata?(sys_id, module_name, index))
      @logger.debug("websocket exec could not find module: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
      error_response(request_id, ErrorCode::ModuleNotFound, "could not find module: mod=#{module_name}")
      return
    end

    unless function_present?(metadata.functions, name)
      @logger.debug("websocket exec could not find function: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
      error_response(request_id, ErrorCode::BadRequest, "could not find function: name=#{name}")
      return
    end

    unless function_visible?(metadata.security, name)
      @logger.warn("websocket exec attempted to access priviled function: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
      error_response(request_id, ErrorCode::AccessDenied, "attempted to access privileged function")
      return
    end

    # TODO: Make request to core
    # - Locate core responsible for module through consistent hashing
    # - Make request to core
    # - Respond with result
    unless (module_id = module_id?(sys_id, module_name, index))
      @logger.warn("websocket exec could not find module id: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
      error_response(request_id, ErrorCode::RequestFailed, "failed to locate module: mod=#{module_name}")
      return
    end

    core_url = locate_module?(module_id)
    unless core_url
      @logger.warn("websocket exec could not locate module's system: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
      error_response(request_id, ErrorCode::RequestFailed, "failed to locate module: mod=#{module_name}")
      return
    end

    # TODO: Validate response from the module, perhaps a Session::Update
    response = HTTP::Client.post(core_url)
    if response.success?
      response_message = Response.new(
        id: request_id,
        type: Response::Type::Success,
        value: JSON::Any.new response.body,
      )
      respond(response_message)
    else
      @logger.warn("websocket exec failed: sys_id=#{sys_id} module_name=#{module_name} index=#{index} name=#{name}")
      error_response(request_id, ErrorCode::RequestFailed, response.body)
    end
  end

  # Bind a websocket to a module subscription
  #
  def bind(
    request_id : String,
    sys_id : String,
    module_name : String,
    index : Int32,
    name : String
  )
    begin
      # Check if module previously bound
      unless has_binding?(sys_id, module_name, index, name)
        create_binding(request_id, sys_id, module_name, index, name)
      end
    rescue
      @logger.debug("websocket binding could not find system: {sys: #{sys_id}, mod: #{module_name}, index: #{index}, name: #{name}}")
      error_response(request_id, ErrorCode::ModuleNotFound, "could not find module: sys=#{sys_id} mod=#{module_name}")
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
  end

  # Unbind a websocket from a module subscription
  #
  def unbind(
    request_id : String,
    sys_id : String,
    module_name : String,
    index : Int32,
    name : String
  )
    subscription = delete_binding(sys_id, module_name, index, name)
    @@subscriptions.unsubscribe(subscription) if subscription

    respond(Response.new(id: request_id, type: Response::Type::Success))
  end

  def debug
    raise "#debug unimplemented"
  end

  def ignore
    raise "#ignore unimplemented"
  end

  ##############################################################################

  # Looks up the metadata.
  # - checks for fresh value in cache
  # - refreshes cache with new value if present
  #
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
  #
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

  # Check for existing binding to a module
  #
  def has_binding?(sys_id, module_name, index, name)
    @bindings.has_key? Session.binding_key(sys_id, module_name, index, name)
  end

  # Create a binding to a module on the Session
  #
  def create_binding(request_id, sys_id, module_name, index, name)
    pp! request_id, sys_id, module_name, index, name
    key = Session.binding_key(sys_id, module_name, index, name)
    # Subscribe and set local binding
    @bindings[key] = @@subscriptions.subscribe(sys_id, module_name, index, key) do |_, event|
      pp! event
      notify_update(request_id, event)
    end
  end

  # Create a binding to a module on the Session
  #
  def delete_binding(sys_id, module_name, index, name)
    key = Session.binding_key(sys_id, module_name, index, name)
    @bindings.delete key
  end

  # Determine if the function is visible to user
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
  #
  def locate_module?(module_id : String) : URI?
    puts "noop"
    URI.parse("https://core_1")
  end

  # Event handlers
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
  def notify_update(request_id, message)
    update = Update.from_json(message)
    response = Response.new(
      id: request_id,
      type: Response::Type::Notify,
      value: update.value,
      meta: {
        sys:   update.sys_id,
        mod:   update.mod_name,
        index: update.index,
        name:  update.status,
      },
    )
    respond(response)
  end

  # Request handler
  #
  protected def on_message(data)
    # Execute the request
    request = parse_request(data)
    __send__(request) if request
  rescue e
    @logger.error(e, "websocket request failed: data=#{data} request=#{request} error=#{e.inspect_with_backtrace}")
    error_response(request.try(&.id), ErrorCode::RequestFailed, e.message)
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
    @logger.warn("failed to parse: data=#{data} error=#{e.message}")
    error_response(JSON.parse(data)["id"]?.try &.as_s, ErrorCode::BadRequest, "bad request: #{e.message}")
    return
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

  protected def respond(response : Response)
    @ws.send(response.to_json)
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
    when Request::Command::Exec
      args = request.args.as(Array(JSON::Any))
      exec(**arguments.merge({args: args}))
    when Request::Command::Bind
      bind(**arguments)
    when Request::Command::Unbind
      unbind(**arguments)
    when Request::Command::Debug
      debug
    when Request::Command::Ignore
      ignore
    else
      @logger.error("unrecognised websocket command: cmd=#{request.command}")
    end
  end
end
