require "pinger"
require "loki-client"
require "placeos-driver/storage"
require "placeos-driver/proxy/remote_driver"

require "../utilities/module_logs"
require "./application"
require "./drivers"
require "./settings"

module PlaceOS::Api
  # Modules, running instances of drivers that control individual devices and services
  class Modules < Application
    include Utils::CoreHelper
    include Utils::Permissions
    include Utils::GroupPermissions

    base "/api/engine/v2/modules/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [
      :index, :create, :update, :destroy, :show, :start, :stop,
      :state, :state_lookup, :state_value, :ping, :execute, :load, :settings, :logs,
    ]
    # Everything absent from the check_admin list above is gated by a
    # support-subsystem permission on the module's zones instead:
    # show/state/state_lookup/state_value → Read, start/stop/ping/execute/load → Operate,
    # settings → Update, logs → Operate and Read, create/update/destroy → the verb's bit.
    before_action :check_support, only: [:show_error]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_module(id : String)
      Log.context.set(module_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_module = ::PlaceOS::Model::Module.find!(id)
    end

    getter! current_module : ::PlaceOS::Model::Module

    # Permissions
    ###############################################################################################

    # Mutation gate. Admin/support JWT bypass; otherwise the "support"
    # subsystem must grant the verb's permission on the module's zones
    # (legacy org_zone path preserved). A module attached to no system has
    # no derivable zones → admin/support only.
    # NOTE:: if modifying, update Settings#can_modify?
    def can_modify?(mod)
      ensure_support_access!(zones_for_module(mod), verb_permission)
    end

    # Zones a module belongs to: the union of its logic-module system
    # (`control_system_id`) and every system that references it. Empty when
    # the module is attached to no system.
    private def zones_for_module(mod : ::PlaceOS::Model::Module) : Array(String)
      zones = [] of String
      if (cs_id = mod.control_system_id) && (sys = ::PlaceOS::Model::ControlSystem.find?(cs_id))
        zones.concat(sys.zones)
      end
      if (mod_id = mod.id)
        ::PlaceOS::Model::ControlSystem.by_module_id(mod_id).each { |cs| zones.concat(cs.zones) }
      end
      zones.uniq
    end

    # Reading a single module: admin/support JWT and the legacy org_zone path
    # bypass; otherwise a "support" subsystem user needs Read on the module's
    # zones. A module with no derivable zones stays admin/support only.
    @[AC::Route::Filter(:before_action, only: [:show, :state, :state_lookup, :state_value])]
    def check_show_permissions
      ensure_support_access!(zones_for_module(current_module), ::PlaceOS::Model::Permissions::Read)
    end

    # Runtime operations (ping the device, execute a driver method, load the
    # module on core): Operate on the module's zones — same bit as start/stop.
    @[AC::Route::Filter(:before_action, only: [:ping, :execute, :load])]
    def check_operate_permissions
      ensure_support_access!(zones_for_module(current_module), ::PlaceOS::Model::Permissions::Operate)
    end

    # Viewing collated settings exposes configuration, so it requires write
    # level access (Update) rather than Read; encrypted values are still
    # masked for non-support roles by `decrypt_for!`.
    # Debug output can include device traffic and credentials, see
    # `GroupPermissions#module_debug_access?`
    @[AC::Route::Filter(:before_action, only: [:logs])]
    def check_debug_permissions
      raise Error::Forbidden.new unless module_debug_access?(current_module.id.as(String))
    end

    @[AC::Route::Filter(:before_action, only: [:settings])]
    def check_settings_permissions
      ensure_support_access!(zones_for_module(current_module), ::PlaceOS::Model::Permissions::Update)
    end

    @[AC::Route::Filter(:before_action, only: [:index])]
    def check_view_permissions(
      @[AC::Param::Info(description: "only return modules running in this system (query params are ignored if this is provided)", example: "sys-1234")]
      control_system_id : String? = nil,
    )
      # admin/support JWT see everything (no scoping)
      return if user_support?

      org_zone = support_org_zone_id

      if control_system_id
        zones = ::PlaceOS::Model::ControlSystem.find!(control_system_id).zones
        # "support" subsystem: Read on the system's zones.
        return if support_subsystem_grants?(zones, ::PlaceOS::Model::Permissions::Read)
        # legacy org_zone path: the system must include the org_zone and the
        # user must be able to manage it.
        return if org_zone && zones.includes?(org_zone) && check_access(current_user.groups, zones).can_manage?
        raise Error::Forbidden.new
      end

      # Whole-list view: instead of a flat allow/deny, resolve the zone set the
      # caller may see and scope the result set to it (see `index`).
      # legacy org_zone manager -> systems containing the org_zone.
      if org_zone && check_access(current_user.groups, [org_zone]).can_manage?
        @module_scope_zones = [org_zone]
        return
      end

      # "support" subsystem -> systems whose zones the caller can Read.
      accessible = support_accessible_zone_ids(::PlaceOS::Model::Permissions::Read)
      unless accessible.empty?
        @module_scope_zones = accessible
        return
      end

      raise Error::Forbidden.new
    end

    # Zone ids used to scope the module list for non-admin/non-support callers
    # (legacy org_zone, or the caller's reachable "support" zones). Left nil for
    # admin/support callers, who see everything.
    getter module_scope_zones : Array(String)? = nil

    # Response helpers
    ###############################################################################################

    record ControlSystemDetails, name : String, zone_data : Array(::PlaceOS::Model::Zone) do
      include JSON::Serializable
    end

    record DriverDetails, name : String, description : String?, module_name : String? do
      include JSON::Serializable
    end

    # extend the ControlSystem model to handle our return values
    class ::PlaceOS::Model::Module
      @[JSON::Field(key: "driver")]
      property driver_details : Api::Modules::DriverDetails? = nil
      @[JSON::Field(key: "control_system")]
      property control_system_details : Api::Modules::ControlSystemDetails? = nil
      property core_node : String? = nil
    end

    ###############################################################################################

    # return a list of modules configured on the cluster
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "only return modules updated before this time (unix epoch)")]
      as_of : Int64? = nil,
      @[AC::Param::Info(description: "only return modules running in this system (query params are ignored if this is provided)", example: "sys-1234")]
      control_system_id : String? = nil,
      @[AC::Param::Info(description: "only return instances of this driver", example: "driver-1234")]
      driver_id : String? = nil,
      @[AC::Param::Info(description: "do not return logic modules (return only modules that can exist in multiple systems)", example: "true")]
      no_logic : Bool = false,
      @[AC::Param::Info(description: "return only running modules", example: "true")]
      running : Bool? = nil,
    ) : Array(::PlaceOS::Model::Module)
      # if a system id is present we query the database directly
      if control_system_id
        cs = ::PlaceOS::Model::ControlSystem.find!(control_system_id)
        # Include subset of association data with results
        results = ::PlaceOS::Model::Module.find_all(cs.modules).compact_map do |mod|
          next if (driver = mod.driver).nil?

          # Most human readable module data is contained in driver
          mod.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
          mod
        end.to_a

        set_collection_headers(results.size, ::PlaceOS::Model::Module.table_name)

        return results
      end

      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::Module.all

      # TODO:: we can remove this once there is a tenant_id field on modules
      # which will make this much simpler to filter
      if scope_zones = module_scope_zones
        # we only want to show modules in use by systems within these zones
        no_logic = true

        # find all the non-logic modules that this user can access
        # 1. grab all the module ids in systems whose zones overlap scope_zones
        # 2. select distinct module ids which are not logic modules (99)
        placeholders = (1..scope_zones.size).map { |i| "$#{i}" }.join(", ")
        sql_query = %[
          WITH matching_rows AS (
            SELECT unnest(modules) AS module_id
            FROM sys
            WHERE zones && ARRAY[#{placeholders}]::text[]
          )

          SELECT ARRAY_AGG(DISTINCT m.module_id)
          FROM matching_rows m
          JOIN mod ON m.module_id = mod.id
          WHERE mod.role <> 99;
        ]

        module_ids = PgORM::Database.connection do |conn|
          conn.query_one(sql_query, args: scope_zones.map(&.as(PgORM::Value)), &.read(Array(String)?))
        end || [] of String

        if module_ids.empty?
          set_collection_headers(0, ::PlaceOS::Model::Module.table_name)
          return [] of ::PlaceOS::Model::Module
        end

        # NOTE: the Elasticsearch version ANDed each id as a separate term
        # filter, returning nothing whenever a scoped user could access more
        # than one module — this is the intended IN() semantics
        query = query.where(id: module_ids)
      end

      if no_logic
        query = query.where("role != ?", Model::Driver::Role::Logic.to_i)
      end

      if driver_id
        query = query.where(driver_id: driver_id)
      end

      unless running.nil?
        query = query.where(running: running)
      end

      if as_of
        # as_of is epoch seconds; compare at second granularity (the ES
        # pipeline stored epoch-second integers, so lte was second-precise —
        # a naive <= would exclude rows with sub-second timestamps)
        query = query.where("updated_at < ?", Time.unix(as_of + 1))
      end

      # searching also matches text on the parent driver — parity with the
      # Elasticsearch has_parent(Driver) query (search modules by driver name)
      if tsq = search_tsquery
        query = query.where(
          "(search_vector @@ to_tsquery('simple', ?) OR EXISTS (SELECT 1 FROM driver d WHERE d.id = mod.driver_id AND d.search_vector @@ to_tsquery('simple', ?)))",
          tsq, tsq
        )
      end

      search_results = paginate_sql(
        query.order("custom_name, name, id"),
        ::PlaceOS::Model::Module.table_name,
        limit: search_limit,
        offset: search_offset,
      )

      # Include subset of association data with results
      # avoid n+1 requests
      control_system_ids = search_results.compact_map(&.control_system_id).uniq!
      drivers = Model::Driver.find_all search_results.map(&.driver_id.as(String)).uniq!

      control_systems = Model::ControlSystem.find_all(control_system_ids).to_a
      zones = Model::Zone.find_all(control_systems.flat_map(&.zones)).to_a

      search_results.compact_map do |d|
        sys_id = d.control_system_id
        sys = sys_id ? control_systems.find { |csys| csys.id == sys_id } : nil
        d_id = d.driver_id.as(String)
        driver = drivers.find { |drive| drive.id == d_id }
        next unless driver

        # Include control system on Logic modules so it is possible
        # to display the inherited settings
        sys_field = if sys
                      ControlSystemDetails.new(sys.name, sys.zones.compact_map { |zid| zones.find { |zone| zone.id == zid } })
                    else
                      nil
                    end

        d.control_system_details = sys_field
        d.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)

        # grab connected state from redis
        d.connected = if d.running
                        storage = Driver::RedisStorage.new(d.id.as(String))
                        storage["connected"]? != "false"
                      else
                        true
                      end

        d
      end
    end

    # return the details of a module
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "return the driver details along with the module?", example: "true")]
      complete : Bool = false,
    ) : ::PlaceOS::Model::Module
      running_on = self.class.locate_module(current_module.id.as(String)) rescue nil
      current_module.core_node = running_on

      # grab connected state from redis
      current_module.connected = if current_module.running
                                   storage = Driver::RedisStorage.new(current_module.id.as(String))
                                   storage["connected"]? != "false"
                                 else
                                   true
                                 end

      if complete && (driver = current_module.driver)
        current_module.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
        if sys = current_module.control_system
          current_module.control_system_details = ControlSystemDetails.new(sys.name, ::PlaceOS::Model::Zone.find_all(sys.zones).to_a)
        end
        current_module
      else
        current_module
      end
    end

    # return runtime error log of a module (if any) or 404
    @[AC::Route::GET("/:id/error")]
    def show_error : Array(String)
      raise Error::NotFound.new("No associated error logs found for module '#{current_module.id}'") unless current_module.has_runtime_error
      error_timestamp = current_module.error_timestamp || Time.utc

      client = Loki::Client.from_env
      labels = client.list_labels.data
      stream = labels.try &.includes?("container") ? "container" : "app"
      query = %({#{stream}="core"} | source = "#{current_module.id}" |~ "(?i)exception" | level =~ "ERROR|[E]")
      results = client.query_range(query, 20, error_timestamp - 1.hour, error_timestamp, Loki::Direction::Backward)
      entries = Array(String).new
      results.response_data.result.as(Loki::Model::Streams).each do |res_stream|
        res_stream.entries.each { |entry| entries << (entry.line.try &.gsub("+ ", "") || "\n") }
      end

      entries
    end

    # update the details of a module
    @[AC::Route::PATCH("/:id", body: :mod)]
    @[AC::Route::PUT("/:id", body: :mod)]
    def update(mod : ::PlaceOS::Model::Module) : ::PlaceOS::Model::Module
      current = current_module
      can_modify?(current)
      current.assign_attributes(mod)
      can_modify?(current)

      raise Error::ModelValidation.new(current.errors) unless current.save

      if driver = current.driver
        current.driver_details = DriverDetails.new(driver.name, driver.description, driver.module_name)
      end
      current
    end

    # add a new module / instance of a driver
    @[AC::Route::POST("/", body: :mod, status_code: HTTP::Status::CREATED)]
    def create(
      mod : ::PlaceOS::Model::Module,
      @[AC::Param::Info(description: "add the new module to this control system", example: "sys-1234")]
      system_id : String? = nil,
    ) : ::PlaceOS::Model::Module
      if system_id
        # only logic modules have a parent system, and they're added to it by an `after_create` callback
        if cs_id = mod.control_system_id.presence
          raise Error::ModelValidation.new({Error::Field.new(:control_system_id, "must match system_id when both are provided")}) unless cs_id == system_id
        else
          return create_in_system(mod, system_id)
        end
      end

      can_modify?(mod)
      raise Error::ModelValidation.new(mod.errors) unless mod.save
      mod
    end

    # Creates the module and appends it to the system atomically, so a failure
    # adding it to the system doesn't leave an orphaned module behind.
    private def create_in_system(mod : ::PlaceOS::Model::Module, system_id : String) : ::PlaceOS::Model::Module
      sys = ::PlaceOS::Model::ControlSystem.find!(system_id)

      # the module isn't in any system yet, so the target system's zones are the only ones that apply.
      # Adding to the system requires the same access as `PUT /systems/:sys_id/module/:module_id`
      ensure_support_access!(sys.zones, verb_permission)
      ensure_support_access!(sys.zones, ::PlaceOS::Model::Permissions::Update, admin_required: true)

      ::PgORM::Database.transaction do |_tx|
        raise Error::ModelValidation.new(mod.errors) unless mod.save
        raise "Failed to add ControlSystem Module" unless ::PlaceOS::Model::ControlSystem.add_module(system_id, mod.id.as(String))
      end

      mod
    end

    # remove a module
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      can_modify?(current_module)
      current_module.destroy
    end

    # Receive the collated settings for a module
    @[AC::Route::GET("/:id/settings")]
    def settings : Array(::PlaceOS::Model::Settings)
      Api::Settings.collated_settings(current_user, current_module)
    end

    # Starts a module
    @[AC::Route::POST("/:id/start")]
    def start : Nil
      return if current_module.running == true
      ensure_support_access!(zones_for_module(current_module), ::PlaceOS::Model::Permissions::Operate)
      current_module.update_fields(running: true)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "start", module_id: current_module.id, event: "failed"} }
        raise "failed to update database to start module #{current_module.id}"
      end
    end

    # Stops a module
    @[AC::Route::POST("/:id/stop")]
    def stop : Nil
      return unless current_module.running
      ensure_support_access!(zones_for_module(current_module), ::PlaceOS::Model::Permissions::Operate)
      current_module.update_fields(running: false)

      # Changes cleared on a successful update
      if current_module.running_changed?
        Log.error { {controller: "Modules", action: "stop", module_id: current_module.id, event: "failed"} }
        raise "failed to update database to stop module #{current_module.id}"
      end
    end

    # Executes a command on a module
    # The `/systems/` route can be used to introspect modules for the list of methods and argument requirements
    @[AC::Route::POST("/:id/exec/:method", body: :args)]
    def execute(
      id : String,
      @[AC::Param::Info(description: "the name of the methodm we want to execute")]
      method : String,
      @[AC::Param::Info(description: "the arguments we want to provide to the method")]
      args : Array(JSON::Any),
    ) : Nil
      sys_id = current_module.control_system_id || ""

      result, status_code = Driver::Proxy::RemoteDriver.new(
        module_id: id,
        sys_id: sys_id,
        module_name: current_module.name,
        user_id: current_user.id,
      ) { |module_id|
        ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
      }.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )

      # customise the response based on the execute results
      response.content_type = "application/json"
      render text: result, status: status_code
    rescue e : Driver::Proxy::RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        sys_id:      sys_id,
        module_id:   id,
        module_name: current_module.name,
        method:      method,
      } }

      if Api.production?
        render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message)
      else
        render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message, backtrace: e.backtrace?)
      end
    end

    # Dumps the complete status state of the module, key values are serialised JSON
    @[AC::MCP(resource: "placeos://modules/{id}/state", mime_type: "application/json", cache_ttl: 0)]
    @[AC::Route::GET("/:id/state")]
    def state : Hash(String, String)
      self.class.module_state(current_module)
    end

    # Returns the value of the requested status variable as JSON, `null` when it isn't set.
    # Subscribe to the resource to be notified when the value changes
    @[AC::MCP(resource: "placeos://modules/{id}/state/{key}", mime_type: "application/json", subscribe: true, cache_ttl: 0)]
    @[AC::Route::GET("/:id/state/:key/value")]
    def state_value(
      @[AC::Param::Info(description: "the name of the status variable", example: "power")]
      key : String,
    ) : Nil
      # the value is stored as JSON, render it as is
      render json: (Driver::RedisStorage.new(current_module.id.as(String))[key]? || "null")
    end

    # Returns the value of the requested status variable, serialised JSON (`"null"` when it isn't set)
    @[AC::Route::GET("/:id/state/:key")]
    def state_lookup(
      @[AC::Param::Info(description: "that name of the status we are after")]
      key : String,
    ) : String
      Driver::RedisStorage.new(current_module.id.as(String))[key]? || "null"
    end

    # the longest module logs capture, 36 hours
    LOGS_MAX_SECONDS = 36 * 60 * 60

    # Captures the module's debug output for a period of time, as lines of
    # `<time> <LEVEL> <message>`. Over HTTP the lines are streamed as they arrive.
    # MCP clients receive them once the capture ends, so capturing for more than a
    # minute may not work with all clients. The output is limited to 3 MiB.
    @[AC::MCP(resource: "placeos://modules/{id}/logs{?seconds,level}", mime_type: "text/plain", long_running: true, max_bytes: 3_145_728, cache_ttl: 0)]
    @[AC::Route::GET("/:id/logs")]
    def logs(
      @[AC::Param::Info(description: "how long to capture logs for, in seconds, up to 129600 (36 hours)", example: "30")]
      seconds : Int32 = 30,
      # a String, as `Log::Severity` params don't resolve: `Log` is shadowed by the controller's logger
      @[AC::Param::Info(description: "the minimum level of the lines captured: trace, debug, info, notice, warn, error or fatal", example: "info")]
      level : String = "debug",
    ) : Nil
      unless 1 <= seconds <= LOGS_MAX_SECONDS
        raise AC::Route::Param::ValueError.new("must be between 1 and #{LOGS_MAX_SECONDS}", "seconds")
      end
      severity = ::Log::Severity.parse?(level)
      raise AC::Route::Param::ValueError.new("must be one of trace, debug, info, notice, warn, error or fatal", "level") if severity.nil? || severity.none?

      capture = Utils::ModuleLogCapture.new(response, severity)
      socket = begin
        Utils::ModuleLogs.open(module_id: current_module.id.as(String), user_id: user_token.id, request_id: request_id) do |message_level, message|
          capture.write(message_level, message)
        end
      rescue error
        Log.warn(exception: error) { "failed to connect to the module debugger" }
        raise Error::BadGateway.new("failed to connect to the module debugger: #{error.message}")
      end

      # stream the lines as they arrive
      response.status = HTTP::Status::OK
      response.content_type = "text/plain"
      @__render_called__ = true
      spawn(name: "module_logs_#{current_module.id}") do
        socket.run
      ensure
        # core closed the socket
        capture.stop
      end
      begin
        capture.wait(seconds.seconds, mcp_context)
      ensure
        socket.close
      end
    end

    record PingResult, host : String, pingable : Bool?, warning : String?, exception : String? do
      include JSON::Serializable
    end

    # pings the ip or hostname specified in the modules configuration
    @[AC::Route::POST("/:id/ping")]
    def ping : PingResult
      if current_module.role.logic?
        Log.debug { {controller: "Modules", action: "ping", module_id: current_module.id, role: current_module.role.to_s} }
        raise Error::ModelValidation.new({Error::Field.new(:role, "ping not supported for module role: #{current_module.role}")})
      else
        pinger = Pinger.new(current_module.hostname.as(String), count: 3)
        pinger.ping
        PingResult.new(
          host: pinger.ip.to_s,
          pingable: pinger.pingable,
          warning: pinger.warning,
          exception: pinger.exception,
        )
      end
    end

    # Loads the module if not already loaded
    # If the module is already running, it will be updated to latest settings.
    @[AC::Route::POST("/:id/load")]
    def load(id : String) : Bool
      Api::Systems.core_for(id, request_id, &.load(id))
    end

    # Helpers
    ############################################################################

    def self.driver_compiled?(mod : ::PlaceOS::Model::Module, request_id : String)
      if (driver = mod.driver).nil?
        Log.error { "failed to load Module<#{mod.id}>'s Driver<#{mod.driver_id}>" }
        return false
      end

      if (repository = driver.repository).nil?
        Log.error { "failed to load Driver<#{driver.id}>'s Repository<#{driver.repository_id}>" }
        return false
      end

      Api::Drivers.driver_compiled?(driver, repository, request_id, mod.id.as(String))
    end

    def self.module_state(mod : ::PlaceOS::Model::Module | String) : Hash(String, String)
      id = mod.is_a?(String) ? mod : mod.id.as(String)
      Driver::RedisStorage.new(id).to_h
    end

    # Use consistent hashing to determine the location of the module
    def self.locate_module(module_id : String) : String?
      node = RemoteDriver.default_discovery.find?(module_id)
      return nil unless node
      node.to_s
    end
  end
end
