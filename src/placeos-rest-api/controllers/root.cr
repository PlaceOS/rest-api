require "./application"
require "../utilities/core_discovery"

require "rethinkdb"
require "rethinkdb-orm"
require "search-ingest/client"
require "placeos-frontend-loader/client"

require "placeos-models/version"
require "path"
require "uri"

module PlaceOS::Api
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

    @[AC::Route::GET("/")]
    def root : Nil
      raise "not healthy" unless self.class.healthcheck?
    end

    def self.healthcheck? : Bool
      Promise.all(
        Promise.defer {
          check_resource?("redis") { ::PlaceOS::Driver::RedisStorage.with_redis &.ping }
        },
        Promise.defer {
          check_resource?("etcd") { Discovery::Core.instance.etcd &.maintenance.status }
        },
        Promise.defer {
          check_resource?("rethinkdb") { rethinkdb_healthcheck }
        },
      ).then(&.all?).get
    end

    private def self.check_resource?(resource)
      Log.trace { "healthchecking #{resource}" }
      !!yield
    rescue e
      Log.error(exception: e) { {"connection check to #{resource} failed"} }
      false
    end

    private class_getter rethinkdb_admin_connection : RethinkDB::Connection do
      RethinkDB.connect(
        host: RethinkORM.settings.host,
        port: RethinkORM.settings.port,
        db: "rethinkdb",
        user: RethinkORM.settings.user,
        password: RethinkORM.settings.password,
        max_retry_attempts: 1,
      )
    end

    private def self.rethinkdb_healthcheck
      RethinkDB
        .table("server_status")
        .pluck("id", "name")
        .run(rethinkdb_admin_connection)
        .first?
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

    @[AC::Route::GET("/platform")]
    def platform_info : PlatformInfo
      Root.platform_info
    end

    class_getter platform_info : PlatformInfo = PlatformInfo.new

    # Versions
    ###############################################################################################

    @[AC::Route::GET("/version")]
    def version : PlaceOS::Model::Version
      Root.version
    end

    @[AC::Route::GET("/cluster/versions")]
    def cluster_version : Array(PlaceOS::Model::Version)
      Root.construct_versions
    end

    # NOTE: Lazy getter ensures SCOPES array is referenced after all scopes have been appended
    class_getter(scopes) { SCOPES }

    @[AC::Route::GET("/scopes")]
    def scopes : Array(String)
      Root.scopes
    end

    ###############################################################################################

    class_getter version : PlaceOS::Model::Version do
      PlaceOS::Model::Version.new(
        service: APP_NAME,
        commit: BUILD_COMMIT,
        version: VERSION,
        build_time: BUILD_TIME
      )
    end

    SERVICES = %w(core dispatch frontend_loader rest_api search_ingest source triggers)

    def self.construct_versions : Array(PlaceOS::Model::Version)
      version_channel = Channel(PlaceOS::Model::Version?).new
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

      Array(PlaceOS::Model::Version?).new(SERVICES.size) do
        version_channel.receive
      end.compact
    end

    class_getter rest_api_version : PlaceOS::Model::Version = Root.version

    protected def self.frontend_loader_version : PlaceOS::Model::Version
      FrontendLoader::Client.client(&.version)
    end

    protected def self.search_ingest_version : PlaceOS::Model::Version
      SearchIngest::Client.client(&.version)
    end

    protected def self.core_version : PlaceOS::Model::Version
      Api::Systems.core_for("version", &.version)
    end

    protected def self.triggers_version : PlaceOS::Model::Version
      trigger_uri = TRIGGERS_URI.dup
      trigger_uri.path = "/api/triggers/v2/version"
      response = HTTP::Client.get trigger_uri
      PlaceOS::Model::Version.from_json(response.body)
    end

    protected def self.dispatch_version : PlaceOS::Model::Version
      uri = URI.new(host: PLACE_DISPATCH_HOST, port: PLACE_DISPATCH_PORT, scheme: "http")
      response = HTTP::Client.get "#{uri}/api/dispatch/v1/version"
      PlaceOS::Model::Version.from_json(response.body)
    end

    protected def self.source_version : PlaceOS::Model::Version
      uri = URI.new(host: PLACE_SOURCE_HOST, port: PLACE_SOURCE_PORT, scheme: "http")
      response = HTTP::Client.get "#{uri}/api/source/v1/version"
      PlaceOS::Model::Version.from_json(response.body)
    end

    # Can be used in a similar manner to a webhook for drivers
    @[AC::Route::POST("/signal")]
    def signal(
      @[AC::Param::Info(description: "the path we would like to send data to", example: "/my/data/channel")]
      channel : String
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

      path = Path["placeos/"].join(channel).to_s
      Log.info { "signalling #{path} with #{payload.bytesize} bytes" }

      ::PlaceOS::Driver::RedisStorage.with_redis &.publish(path, payload)
    end

    @[AC::Route::POST("/reindex")]
    def reindex(
      @[AC::Param::Info(description: "backfill the database after re-indexing?", example: "true")]
      backfill : Bool = false
    ) : Nil
      success = SearchIngest::Client.client &.reindex(backfill: backfill)
      raise "reindex failed" unless success
    end

    @[AC::Route::POST("/backfill")]
    def backfill
      success = SearchIngest::Client.client &.backfill
      raise "backfill failed" unless success
    end
  end
end
