require "placeos-driver/proxy/remote_driver"

require "./group_permissions"
require "./permissions"

module PlaceOS::Api
  # A module's debug output, streamed from the core instance running it. Used by
  # the websocket `debug` command and the `GET /modules/:id/logs` capture
  module Utils::ModuleLogs
    # Opens the module's debug socket on core, calling the block with each message.
    # The socket isn't running, call `run` (it blocks until the socket closes) and
    # `close` it when done
    def self.open(
      module_id : String,
      user_id : String?,
      sys_id : String = "",
      request_id : String? = nil,
      discovery : Clustering::Discovery = Driver::Proxy::RemoteDriver.default_discovery,
      &block : ::Log::Severity, String -> Nil
    ) : HTTP::WebSocket
      driver = Driver::Proxy::RemoteDriver.new(
        module_id: module_id,
        sys_id: sys_id,
        module_name: module_id,
        discovery: discovery,
        user_id: user_id,
      ) { |id|
        ::PlaceOS::Model::Module.find!(id).edge_id.as(String)
      }

      socket = driver.debug(request_id)
      socket.on_message do |message|
        level_value, text = Tuple(Int32, String).from_json(message)
        block.call(::Log::Severity.from_value(level_value), text)
      rescue error
        Log.warn(exception: error) { "failed to forward debug message" }
      end
      socket
    end
  end

  # Checks a websocket user's access to module debug output, see
  # `GroupPermissions#module_debug_access?`. Created per check, so the
  # permission memos never outlive it.
  class Utils::ModuleDebugAccess
    include Utils::Permissions
    include Utils::GroupPermissions

    def self.allowed?(user_token : ::PlaceOS::Model::UserJWT, module_id : String) : Bool
      new(user_token).module_debug_access?(module_id)
    end

    def initialize(@user_token : ::PlaceOS::Model::UserJWT)
    end

    def user_support? : Bool
      @user_token.is_support? || @user_token.is_admin?
    end

    getter current_user : ::PlaceOS::Model::User { ::PlaceOS::Model::User.find!(@user_token.id) }

    getter current_authority : ::PlaceOS::Model::Authority? { ::PlaceOS::Model::Authority.find_by_domain(@user_token.domain) }
  end

  # Captures log lines, `<time> <LEVEL> <message>`, to an output for a period of
  # time. Lines are written as they arrive, so nothing is held in memory: an HTTP
  # response streams them and an MCP request spools them to disk.
  #
  # The capture ends when the period elapses, `max_bytes` is reached (a marker is
  # written), the output fails (the client disconnected), the MCP request is
  # cancelled or it's stopped
  class Utils::ModuleLogCapture
    MAX_BYTES = 3 * 1024 * 1024

    TRUNCATED = "[truncated: the 3 MiB limit was reached]\n"

    # how often progress is reported to MCP clients
    PROGRESS_INTERVAL = 5.seconds

    getter bytes_written : Int64 = 0_i64
    getter? finished : Bool = false

    @lock = Mutex.new
    @stop = Channel(Nil).new(1)

    def initialize(@output : IO, @level : ::Log::Severity = ::Log::Severity::Debug, @max_bytes : Int64 = MAX_BYTES.to_i64)
    end

    # writes the message, if it's at or above the level
    def write(severity : ::Log::Severity, message : String) : Nil
      return if severity < @level
      line = "#{Time.utc.to_rfc3339(fraction_digits: 3)} #{severity.label} #{message}\n"
      @lock.synchronize do
        return if @finished
        if @bytes_written + line.bytesize + TRUNCATED.bytesize > @max_bytes
          @output << TRUNCATED
          @output.flush
          stop
          return
        end
        @output << line
        @output.flush
        @bytes_written += line.bytesize
      end
    rescue IO::Error | HTTP::Server::ClientError
      # the client disconnected
      stop
    end

    # waits until the period elapses or the capture finishes, reporting progress
    def wait(period : Time::Span, context : ActionController::MCPServer::RequestContext? = nil) : Nil
      started = Time.instant
      deadline = started + period
      cancelled = context.try(&.done) || Channel(Nil).new

      loop do
        remaining = deadline - Time.instant
        break if remaining <= Time::Span.zero

        select
        when @stop.receive
          break
        when cancelled.receive?
          break
        when timeout({remaining, PROGRESS_INTERVAL}.min)
          context.try &.progress((Time.instant - started).total_seconds.to_i, period.total_seconds.to_i)
        end
      end
      @lock.synchronize { @finished = true }
    end

    # ends the capture, i.e. when the debug socket closes
    def stop : Nil
      @finished = true
      select
      when @stop.send(nil)
      else
        # already stopping
      end
    end
  end
end
