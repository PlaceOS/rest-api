require "redis_service_manager"
require "mutex"
require "placeos-driver/proxy/remote_driver"
require "tasker"

require "../error"
require "../utilities/module_logs"
require "../utilities/params"
require "../utilities/permissions"

module PlaceOS::Api::WebSocket
  class Session
    include Utils::Permissions

    Log = ::Log.for(self)

    # Class level subscriptions to modules
    class_getter subscriptions : Driver::Proxy::Subscriptions = Driver::Proxy::Subscriptions.new

    # Local subscriptions
    private getter bindings = {} of {String, String, Int32, String, Bool} => Driver::Subscriptions::Subscription

    # Caching
    private getter cache_lock = Mutex.new
    private getter cache_timeout : Time::Span = 10.minutes

    # Background task to clear module metadata caches
    private getter cache_cleaner : Tasker::Task?

    private getter metadata_cache = {} of String => Driver::DriverModel::Metadata
    private getter module_id_cache = {} of String => String

    private getter write_channel = Channel(String).new

    private getter ws : HTTP::WebSocket

    private getter user : ::PlaceOS::Model::UserJWT

    # Organisations the session may touch; nil for cluster reach (PPT-526)
    private getter organisation_ids : Set(UUID)?

    def initialize(
      @ws : HTTP::WebSocket,
      @request_id : String,
      @user : ::PlaceOS::Model::UserJWT,
      @discovery : Clustering::Discovery = RemoteDriver.default_discovery,
      @organisation_ids : Set(UUID)? = nil,
      @authorizer : Proc(String, ::PlaceOS::Model::Permissions, Bool)? = nil,
      @security_authorizer : Proc(String, Driver::Proxy::RemoteDriver::Clearance)? = nil,
      @module_debug_authorizer : Proc(String, Bool)? = nil,
    )
      # Register event handlers
      ws.on_message do |message|
        Log.trace { {frame: "TEXT", text: message} }
        spawn do
          on_message(message)
        end
      end

      ws.on_ping do
        Log.trace { {frame: "PING"} }
        ws.pong
      end

      @security_level = if user.is_admin?
                          Driver::Proxy::RemoteDriver::Clearance::Admin
                        elsif user.is_support?
                          Driver::Proxy::RemoteDriver::Clearance::Support
                        else
                          Driver::Proxy::RemoteDriver::Clearance::User
                        end

      # Empty's metadata cache upon cache_timeout
      @cache_cleaner = Tasker.instance.every(cache_timeout) { clear_caches }

      # Perform writes
      spawn(name: "socket_writes_#{request_id}") { run_writes }
    end

    # WebSocket API Handlers
    ##############################################################################

    # The selected organisation is immutable for the life of the socket.
    protected def system_in_reach?(system_id : String) : Bool
      ids = organisation_ids
      return true if ids.nil?
      system = ::PlaceOS::Model::ControlSystem.find?(system_id)
      return false if system.nil?
      owner_in_scope?(system.organisation_id)
    end

    private def owner_in_scope?(owner : UUID?) : Bool
      ids = organisation_ids
      ids.nil? || (!owner.nil? && ids.includes?(owner))
    end

    private def scope_permitted?(system_id : String, required : ::PlaceOS::Model::Permissions) : Bool
      authorizer = @authorizer
      authorizer.nil? || authorizer.call(system_id, required)
    rescue error
      Log.warn(exception: error) { "websocket authorisation could not be verified" }
      false
    end

    private def scoped_security(system_id : String) : Driver::Proxy::RemoteDriver::Clearance
      authorizer = @security_authorizer
      authorizer ? authorizer.call(system_id) : @security_level
    rescue error
      Log.warn(exception: error) { "websocket clearance could not be verified" }
      Driver::Proxy::RemoteDriver::Clearance::User
    end

    # Validate the current database ownership, not a possibly stale Redis lookup.
    private def module_in_scope?(system_id : String, module_name : String, index : Int32, interface : Bool = false, triggers : Bool = true) : Bool
      return true if @authorizer.nil?
      return true if triggers && !interface && module_name == "_TRIGGER_"
      !scoped_module(system_id, module_name, index, interface).nil?
    end

    private def scoped_module(system_id : String, module_name : String, index : Int32, interface : Bool = false) : ::PlaceOS::Model::Module?
      return unless index > 0
      system = ::PlaceOS::Model::ControlSystem.find?(system_id)
      return unless system && owner_in_scope?(system.organisation_id)
      mod = if interface
              interface_driver(system_id, module_name, index)
            else
              remaining = index
              found = nil.as(::PlaceOS::Model::Module?)
              system.modules.each do |module_id|
                candidate = ::PlaceOS::Model::Module.find?(module_id)
                next unless candidate && candidate.resolved_name == module_name
                remaining -= 1
                next unless remaining.zero?
                found = candidate
                break
              end
              found
            end
      return unless mod && system.modules.includes?(mod.id.to_s) && mod.organisation_id == system.organisation_id
      if parent_id = mod.control_system_id.presence
        parent = ::PlaceOS::Model::ControlSystem.find?(parent_id)
        return unless parent && parent.organisation_id == system.organisation_id && parent.modules.includes?(mod.id.as(String))
      end
      unless interface
        runtime_id = Driver::Proxy::System.module_id?(system_id, module_name, index)
        return if runtime_id && runtime_id != mod.id
      end
      mod
    rescue Driver::Proxy::RemoteDriver::Error
      nil
    end

    private def debug_module_in_scope?(system_id : String, module_id : String) : Bool
      return true if @authorizer.nil?
      mod = ::PlaceOS::Model::Module.find?(module_id)
      return false unless mod && owner_in_scope?(mod.organisation_id)
      if parent_id = mod.control_system_id.presence
        parent = ::PlaceOS::Model::ControlSystem.find?(parent_id)
        return false unless parent && parent.organisation_id == mod.organisation_id && parent.modules.includes?(module_id)
      end
      # Standalone debugging has always used a module id (or empty string)
      # as location metadata. An explicit real system must actually contain it.
      return true if system_id.empty? || system_id == module_id
      system = ::PlaceOS::Model::ControlSystem.find?(system_id)
      !!(system && owner_in_scope?(system.organisation_id) && system.modules.includes?(module_id) && mod.organisation_id == system.organisation_id)
    end

    private def debug_allowed?(system_id : String, module_id : String) : Bool
      if authorize = @module_debug_authorizer
        return authorize.call(module_id)
      end
      return Utils::ModuleDebugAccess.allowed?(user, module_id) unless @authorizer
      clearance = scoped_security(system_id)
      return true if clearance.admin? || clearance.support?

      # A live cross-organisation Read|Operate grant was checked on the frame.
      # Home-organisation users still need the existing module/group access.
      authority = ::PlaceOS::Model::Authority.find_by_domain(user.domain)
      system = ::PlaceOS::Model::ControlSystem.find?(system_id)
      if authority && system && authority.organisation_id != system.organisation_id
        return true
      end
      metadata = user.user
      scoped_user = ::PlaceOS::Model::UserJWT.new(
        iss: user.iss,
        iat: user.iat,
        exp: user.exp,
        domain: user.domain,
        id: user.id,
        scope: user.scope,
        user: ::PlaceOS::Model::UserJWT::Metadata.new(
          name: metadata.name,
          email: metadata.email,
          permissions: ::PlaceOS::Model::UserJWT::Permissions::User,
          roles: metadata.roles,
        ),
      )
      Utils::ModuleDebugAccess.allowed?(scoped_user, module_id)
    rescue error
      Log.warn(exception: error) { "websocket debug authorisation could not be verified" }
      false
    end

    protected def elevate_security(system_id : String, default : Driver::Proxy::RemoteDriver::Clearance) : Driver::Proxy::RemoteDriver::Clearance
      return default if default.admin?

      # check if this user has elevated privaleges on this system
      authority = ::PlaceOS::Model::Authority.find_by_domain(user.domain)
      org_zone_id = authority.try(&.config["org_zone"]?.try(&.as_s?))
      return default unless org_zone_id

      system = ::PlaceOS::Model::ControlSystem.find!(system_id)
      zones = system.zones
      return default unless zones.includes?(org_zone_id)

      groups = if @authorizer && !user.guest_scope?
                 ::PlaceOS::Model::User.find?(user.id).try(&.groups) || [] of String
               else
                 user.user.roles
               end
      access = check_access(groups, zones)
      case access
      in .deny?
        raise "you have been denied access to this system"
      in .none?
        default
      in .manage?
        Driver::Proxy::RemoteDriver::Clearance::Support
      in .admin?
        Driver::Proxy::RemoteDriver::Clearance::Admin
      end
    end

    # Grab core url for the module and dial an exec request
    #
    def exec(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String,
      args : Array(JSON::Any)?,
      interface : Bool = false,
    )
      args = [] of JSON::Any if args.nil?
      Log.info { {message: "exec", args: args.to_json, user: @user.id} }

      security = elevate_security(system_id, scoped_security(system_id))

      arguments = {
        sys_id:      system_id,
        module_name: module_name,
        index:       index,
        discovery:   @discovery,
        user_id:     user.id,
      }
      edge_id = ->(module_id : String) {
        ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
      }
      driver = if @authorizer
                 scoped_module(system_id, module_name, index, interface)
               elsif interface
                 interface_driver(system_id, module_name, index)
               end
      if @authorizer && driver.nil?
        respond error_response(request_id, :module_not_found, "could not find module: sys=#{system_id} mod=#{module_name}", 404)
        return
      end
      remote_driver = if driver
                        Driver::Proxy::RemoteDriver.new(**arguments, module_id: driver.id.as(String), &edge_id)
                      else
                        Driver::Proxy::RemoteDriver.new(**arguments, &edge_id)
                      end
      response, response_code = remote_driver.exec(
        security: security,
        function: name,
        args: args,
        request_id: @request_id
      )

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
        response_code: response_code,
      ))
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message, e.response_code))
    rescue e
      Log.error(exception: e) do
        {
          message: "failed to execute request",
          error:   e.message,
        }
      end
      respond(error_response(request_id, :unexpected_failure, "failed to execute request"))
    end

    # Bind a websocket to a module subscription
    #
    def bind(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String,
      interface : Bool = false,
    )
      Log.debug { "binding to module" }
      begin
        # Check if module previously bound
        unless has_binding?(system_id, module_name, index, name, interface)
          return unless create_binding(request_id, system_id, module_name, index, name, interface)
        end
      rescue error : Driver::Proxy::RemoteDriver::Error
        respond(error_response(request_id, error.error_code, error.message, error.response_code))
        return
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
      Log.error(exception: e) do
        {
          message: "failed to bind",
          error:   e.message,
        }
      end
      respond(error_response(request_id, :unexpected_failure, "failed to bind"))
    end

    # Unbind a websocket from a module subscription
    #
    def unbind(
      request_id : Int64,
      system_id : String,
      module_name : String,
      index : Int32,
      name : String,
      interface : Bool = false,
    )
      Log.debug { "unbind module" }

      subscription = delete_binding(system_id, module_name, index, name, interface)
      self.class.subscriptions.unsubscribe(subscription) if subscription

      respond(Response.new(id: request_id, type: :success))
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      Log.error(exception: e) do
        {
          message: "failed to unbind",
          error:   e.message,
        }
      end
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
      name : String,
    )
      # NOTE: In the interest of saving a redis lookup, the frontend passes
      #       the module_id, rather than name.
      unless debug_allowed?(system_id, module_name) && debug_module_in_scope?(system_id, module_name)
        Log.warn { {message: "websocket debug attempted without access", module_id: module_name} }
        respond error_response(request_id, :access_denied, "attempted to debug a module without access", 403)
        return
      end

      existing_socket = debug_sessions[{system_id, module_name, index}]?

      if !existing_socket || existing_socket.closed?
        ws = Utils::ModuleLogs.open(module_id: module_name, sys_id: system_id, user_id: user.id, discovery: @discovery) do |level, message|
          required = ::PlaceOS::Model::Permissions::Read | ::PlaceOS::Model::Permissions::Operate
          next unless @module_debug_authorizer || scope_permitted?(system_id, required)
          next unless debug_module_in_scope?(system_id, module_name) && debug_allowed?(system_id, module_name)
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
        end

        spawn { ws.run }
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
      name : String,
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
      if module_id = module_id?(system_id, module_name, index)
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

    # Resolve interfaces in system order without loading the driver runtime.
    private def interface_driver(system_id : String, interface : String, index : Int32) : ::PlaceOS::Model::Module
      if index > 0 && (system = ::PlaceOS::Model::ControlSystem.find?(system_id))
        remaining = index
        system.modules.each do |module_id|
          metadata = Driver::Proxy::System.driver_metadata?(module_id)
          next unless metadata && metadata.implements.includes?(interface)

          remaining -= 1
          next unless remaining.zero?
          if mod = ::PlaceOS::Model::Module.find?(module_id)
            return mod
          end
          break
        end
      end

      raise Driver::Proxy::RemoteDriver::Error.new(
        :module_not_found,
        "could not find module: sys=#{system_id} iface=#{interface} index=#{index}",
        system_id: system_id,
        module_name: interface,
        index: index,
        response_code: 404,
      )
    end

    # Check for existing binding to a module
    #
    def has_binding?(system_id, module_name, index, name, interface = false)
      bindings.has_key? Session.binding_key(system_id, module_name, index, name, interface)
    end

    # Create a binding to a module on the Session
    #
    protected def create_binding(request_id, system_id, module_name, index, name, interface = false) : Bool
      key = Session.binding_key(system_id, module_name, index, name, interface)
      driver = interface_driver(system_id, module_name, index) if interface
      resolved_name = driver.try(&.resolved_name) || module_name

      clearance = scoped_security(system_id)
      if resolved_name.starts_with?("_") && !(clearance.admin? || clearance.support?)
        Log.warn { "websocket binding attempted to access privileged module" }
        respond error_response(request_id, :access_denied, "attempted to access protected module")
        return false
      end

      if driver
        bindings[key] = self.class.subscriptions.subscribe(driver.id.as(String), name) do |_, event|
          notify_update(
            request_id: request_id,
            system_id: system_id,
            module_name: module_name,
            status: name,
            index: index,
            value: event,
            interface: interface,
          )
        end
      elsif module_name == "_TRIGGER_"
        # Ensure the trigger exists
        trig = ::PlaceOS::Model::TriggerInstance.find(name)
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
            value: event,
            interface: interface,
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
            value: event,
            interface: interface,
          )
        end
      end

      true
    end

    # Create a binding to a module on the Session
    #
    def delete_binding(system_id, module_name, index, name, interface = false)
      key = Session.binding_key(system_id, module_name, index, name, interface)
      bindings.delete key
    end

    # Event handlers
    ###########################################################################

    # Parse an update from a subscription and pass to listener
    #
    def notify_update(value, request_id, system_id, module_name, index, status, interface : Bool = false)
      return unless scope_permitted?(system_id, ::PlaceOS::Model::Permissions::Read)
      return unless module_in_scope?(system_id, module_name, index, interface)
      if @authorizer && module_name == "_TRIGGER_"
        trigger = ::PlaceOS::Model::TriggerInstance.find?(status)
        return unless trigger && trigger.control_system_id == system_id
      end
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

    # ensure the client is still there, we send pong as the existing clients ignore this
    def ping
      write("pong")
    end

    # Shutdown handler
    #
    def cleanup
      # cleanup the write fiber
      write_channel.close

      # Stop the cache cleaner
      cache_cleaner.try &.cancel
      clear_caches

      # Unbind all modules — release the shared subscriptions
      bindings.each_value { |subscription| self.class.subscriptions.unsubscribe(subscription) }
      bindings.clear

      # Ignore (stop debugging) all modules
      debug_sessions.each_value &.close
      debug_sessions.clear
    end

    # Utilities
    ###########################################################################

    # Index into module websocket sessions
    def self.binding_key(system_id, module_name, index, name, interface = false)
      {system_id, module_name, index, name, interface}
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
      message : String?,
      response_code : Int32? = 500,
    )
      Api::WebSocket::Session::Response.new(
        id: request_id || 0_i64,
        type: :error,
        error_code: error_code,
        message: message || "",
        response_code: response_code
      )
    end

    private def clear_caches
      Log.trace { "cleaning websocket session cache" }
      cache_lock.synchronize do
        @metadata_cache = {} of String => Driver::DriverModel::Metadata
        @module_id_cache = {} of String => String
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

      # Debug is addressed by module id, including modules without a system.
      # Its live module policy replaces the system gate, never an ownership check.
      if request.command.debug? && @module_debug_authorizer
        mod = ::PlaceOS::Model::Module.find?(request.module_name)
        unless mod && owner_in_scope?(mod.organisation_id)
          respond error_response(request.id, :module_not_found, "module outside selection", 404)
          return
        end
        debug(**arguments)
        return
      end

      # Cleanup remains possible after permission revocation.
      unless request.command.unbind? || request.command.ignore?
        unless system_in_reach?(request.system_id)
          Log.warn { {message: "tenancy refused", reason: "system outside selection", system_id: request.system_id, user: @user.id} }
          respond error_response(request.id, :module_not_found, "could not find module: sys=#{request.system_id} mod=#{request.module_name}", 404)
          return
        end
        required = case request.command
                   when .exec?  then ::PlaceOS::Model::Permissions::Operate
                   when .debug? then ::PlaceOS::Model::Permissions::Read | ::PlaceOS::Model::Permissions::Operate
                   else              ::PlaceOS::Model::Permissions::Read
                   end
        unless scope_permitted?(request.system_id, required)
          respond error_response(request.id, :access_denied, "system access denied", 403)
          return
        end
        unless request.command.debug? || module_in_scope?(request.system_id, request.module_name, request.index, request.interface?, triggers: request.command.bind?)
          respond error_response(request.id, :module_not_found, "could not find module: sys=#{request.system_id} mod=#{request.module_name}", 404)
          return
        end
      end

      case request.command
      in .bind?   then bind(**arguments, interface: request.interface?)
      in .unbind? then unbind(**arguments, interface: request.interface?)
      in .debug?  then debug(**arguments)
      in .ignore? then ignore(**arguments)
      in .exec?   then exec(**arguments, args: request.args, interface: request.interface?)
      end
    end
  end
end

require "./session/request"
require "./session/response"
