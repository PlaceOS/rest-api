require "./application"

require "pg-orm"
require "placeos-frontend-loader/client"

require "placeos-models/version"
require "path"
require "uri"

module PlaceOS::Api
  @[AC::MCP(hide: true)]
  class Root < Application
    base "/api/engine/v2/"

    before_action :check_admin, except: [
      :root,
      :scopes,
      :signal,
      :platform_info,
      :cluster_version,
      :version,
    ]

    before_action :can_write_guest, only: [:signal]

    # Healthcheck
    ###############################################################################################

    # skip authentication for the healthcheck
    skip_action :authorize!, only: :root
    skip_action :set_user_id, only: :root

    # returns 200 OK when the service is healthy (can connect to the databases etc)
    @[AC::Route::GET("/")]
    def root : Nil
      Log.context.set(redis_reconnects: WebSocket::Session.subscriptions.@subscriber.reconnect_count.to_s)
      raise "not healthy" unless self.class.healthcheck?
    end

    def self.healthcheck? : Bool
      Promise.all(
        Promise.defer {
          check_resource?("redis") { ::PlaceOS::Driver::RedisStorage.with_redis &.ping }
        },
        Promise.defer {
          check_resource?("postgres") { pg_healthcheck }
        },
      ).then(&.all?).get
    end

    private def self.check_resource?(resource, &)
      Log.trace { "healthchecking #{resource}" }
      !!yield
    rescue e
      Log.error(exception: e) { {"connection check to #{resource} failed"} }
      false
    end

    private def self.pg_healthcheck
      ::DB.connect(pg_healthcheck_url) do |db|
        db.query_all("select datname from pg_stat_activity where datname is not null", as: {String}).first?
      end
    end

    @@pg_healthcheck_url : String? = nil

    private def self.pg_healthcheck_url(timeout = 5)
      @@pg_healthcheck_url ||= begin
        url = PgORM::Settings.to_uri
        uri = URI.parse(url)
        if q = uri.query
          params = URI::Params.parse(q)
          unless params["timeout"]?
            params.add("timeout", timeout.to_s)
          end
          uri.query = params.to_s
          uri.to_s
        else
          "#{url}?timeout=#{timeout}"
        end
      end
    end

    # Platform Information
    ###############################################################################################

    record(
      PlatformInfo,
      version : String = PLATFORM_VERSION,
      changelog : String = PLATFORM_CHANGELOG,
    ) do
      include JSON::Serializable
    end

    # provides release details of the platform
    @[AC::Route::GET("/platform")]
    def platform_info : PlatformInfo
      Root.platform_info
    end

    class_getter platform_info : PlatformInfo = PlatformInfo.new

    # Versions
    ###############################################################################################

    # provides the version of this service
    @[AC::Route::GET("/version")]
    def version : ::PlaceOS::Model::Version
      Root.version
    end

    # provides the core node versions
    @[AC::Route::GET("/cluster/versions")]
    def cluster_version : Array(::PlaceOS::Model::Version)
      Root.construct_versions
    end

    # NOTE: Lazy getter ensures SCOPES array is referenced after all scopes have been appended
    class_getter(scopes) { SCOPES }

    # returns a list of introspected scopes available for use against the API
    @[AC::Route::GET("/scopes")]
    def scopes : Array(String)
      Root.scopes
    end

    ###############################################################################################

    class_getter version : ::PlaceOS::Model::Version do
      ::PlaceOS::Model::Version.new(
        service: APP_NAME,
        commit: BUILD_COMMIT,
        version: VERSION,
        build_time: BUILD_TIME
      )
    end

    SERVICES = %w(core dispatch frontend_loader rest_api source triggers)

    def self.construct_versions : Array(::PlaceOS::Model::Version)
      version_channel = Channel(::PlaceOS::Model::Version?).new
      {% for service in SERVICES %}
        spawn do
          %version = begin
                      {{service.id}}_version
                    rescue e
                      Log.warn(exception: e) do
                        {service: {{ service }}, message: "failed to request version" }
                      end
                      nil
                    end
          version_channel.send(%version)
        end
      {% end %}

      Array(::PlaceOS::Model::Version?).new(SERVICES.size) do
        version_channel.receive
      end.compact
    end

    class_getter rest_api_version : ::PlaceOS::Model::Version = Root.version

    protected def self.frontend_loader_version : ::PlaceOS::Model::Version
      FrontendLoader::Client.client(&.version)
    end

    protected def self.core_version : ::PlaceOS::Model::Version
      Api::Systems.core_for("version", &.version)
    end

    protected def self.triggers_version : ::PlaceOS::Model::Version
      trigger_uri = TRIGGERS_URI.dup
      trigger_uri.path = "/api/triggers/v2/version"
      response = HTTP::Client.get trigger_uri
      ::PlaceOS::Model::Version.from_json(response.body)
    end

    protected def self.dispatch_version : ::PlaceOS::Model::Version
      uri = URI.new(host: PLACE_DISPATCH_HOST, port: PLACE_DISPATCH_PORT, scheme: "http")
      response = HTTP::Client.get "#{uri}/api/dispatch/v1/version"
      ::PlaceOS::Model::Version.from_json(response.body)
    end

    protected def self.source_version : ::PlaceOS::Model::Version
      uri = URI.new(host: PLACE_SOURCE_HOST, port: PLACE_SOURCE_PORT, scheme: "http")
      response = HTTP::Client.get "#{uri}/api/source/v1/version"
      ::PlaceOS::Model::Version.from_json(response.body)
    end

    # Can be used in a similar manner to a webhook for drivers
    # pushes arbitrary data to channels in redis
    @[AC::Route::POST("/signal")]
    def signal(
      @[AC::Param::Info(description: "the path we would like to send data to", example: "/my/data/channel")]
      channel : String,
    ) : Nil
      if user_token.guest_scope?
        raise Error::Forbidden.new("guest scopes can only signal paths that include '/guest/'") unless channel.includes?("/guest/")
      end

      # NOTE:: we don't describe the body in the params as it could be anything
      payload = if body = request.body
                  body.gets_to_end
                else
                  ""
                end

      [Path["placeos/"].join(channel).to_s, Path["placeos/#{current_authority.not_nil!.id}/"].join(channel).to_s].each do |path|
        # path = Path["placeos/#{current_authority.not_nil!.id}/"].join(channel).to_s
        Log.info { "signalling #{path} with #{payload.bytesize} bytes" }
        ::PlaceOS::Driver::RedisStorage.with_redis &.publish(path, payload)
      end
    end

    # MQTT
    ###############################################################################################

    # Where a resync of the MQTT brokers got to, as source reports it
    struct SourceResyncStatus
      include JSON::Serializable

      # idle, clearing, resyncing, complete or failed
      getter state : String
      # whether everything source publishes was removed from the brokers first
      getter? clear : Bool
      getter started_at : Time?
      getter finished_at : Time?
      # retained topics removed, when clearing
      getter cleared : Int64
      # models whose metadata was published again
      getter metadata : Int32
      getter error : String?
    end

    # publishes every module's state and every model's metadata to the MQTT brokers again.
    # With `clear`, everything source publishes is removed from the brokers first, for when
    # what they hold has drifted. Runs in the background: 202 once started, 409 while one is
    # running. Progress is at `GET /source/resync`
    @[AC::Route::POST("/source/resync", status_code: HTTP::Status::ACCEPTED)]
    def source_resync(
      @[AC::Param::Info(description: "remove everything source publishes from the brokers first", example: "true")]
      clear : Bool = false,
    ) : SourceResyncStatus
      response = Root.source_request("POST", "/api/source/v1/resync?clear=#{clear}")
      status = SourceResyncStatus.from_json(response.body)
      render status: :conflict, json: status if response.status_code == 409
      status
    end

    # where the last resync of the MQTT brokers got to
    @[AC::Route::GET("/source/resync")]
    def source_resync_status : SourceResyncStatus
      SourceResyncStatus.from_json(Root.source_request("GET", "/api/source/v1/resync").body)
    end

    protected def self.source_request(method : String, path : String) : HTTP::Client::Response
      uri = URI.new(host: PLACE_SOURCE_HOST, port: PLACE_SOURCE_PORT, scheme: "http")
      response = HTTP::Client.exec(method, "#{uri}#{path}")
      return response if response.success? || response.status_code == 409
      raise "source responded to #{method} #{path} with #{response.status_code}"
    end
  end
end
