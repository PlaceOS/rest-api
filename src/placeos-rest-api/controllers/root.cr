require "./application"
require "../utilities/core_discovery"

require "rethinkdb"
require "rethinkdb-orm"
require "search-ingest/client"
require "placeos-frontend-loader/client"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

require "placeos-models/version"
require "uri"

module PlaceOS::Api
  class Root < Application
    include ::OpenAPI::Generator::Controller
    base "/api/engine/v2/"

    before_action :check_admin, except: [
      :cluster_version,
      :healthz,
      :root,
      :scopes,
      :signal,
      :version,
    ]

    before_action :can_write_guest, only: [:signal]

    # Healthcheck
    ###############################################################################################

    get("/", :root, annotations: @[OpenAPI(<<-YAML
      summary: Healthcheck
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
        500:
          description: Internal Server Error
    YAML
    )]) do
      head self.class.healthcheck? ? HTTP::Status::OK : HTTP::Status::INTERNAL_SERVER_ERROR
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

    get "/platform", :platform_info do
      render json: Root.platform_info
    end

    class_getter platform_info : PlatformInfo = PlatformInfo.new

    # Versions
    ###############################################################################################

    get("/version", :version, annotations: @[OpenAPI(<<-YAML
      summary: Version of application
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
    YAML
    )]) do
      render json: Root.version
    end

    get("/cluster/versions", :cluster_version, annotations: @[OpenAPI(<<-YAML
    summary: Version of loaded services
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
  YAML
    )]) do
      render json: Root.construct_versions
    end

    # NOTE: Lazy getter ensures SCOPES array is referenced after all scopes have been appended
    class_getter(scopes) { SCOPES }

    get("/scopes", :scopes, annotations: @[OpenAPI(<<-YAML
      summary: Avaliable scopes
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
    YAML
    )]) do
      render json: Root.scopes
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

    class SignalParams < Params
      attribute channel : String, presence: true
    end

    # Can be used in a similar manner to a webhook for drivers
    post("/signal", :signal, annotations: @[OpenAPI(<<-YAML
    summary: Signal on channel?
    parameters:
          #{Schema.qp "channel", "channel to signal on", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
  YAML
    )]) do
      args = SignalParams.new(params).validate!
      channel = args.channel

      if user_token.guest_scope?
        head :forbidden unless channel.includes?("/guest/")
      end

      payload = if body = request.body
                  body.gets_to_end
                else
                  ""
                end

      ::PlaceOS::Driver::RedisStorage.with_redis &.publish("placeos/#{channel}", payload)
      head :ok
    end

    getter? backfill : Bool do
      boolean_param("backfill")
    end

    post("/reindex", :reindex, annotations: @[OpenAPI(<<-YAML
        summary: Reindex RubberSoul
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
          500:
            description: Internal Server Error
      YAML
    )]) do
      success = RubberSoul::Client.client &.reindex(backfill: backfill?)
      head(success ? HTTP::Status::OK : HTTP::Status::INTERNAL_SERVER_ERROR)
    end

    post("/backfill", :backfill, annotations: @[OpenAPI(<<-YAML
        summary: Backfill RubberSoul
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
          500:
            description: Internal Server Error
      YAML
    )]) do
      success = RubberSoul::Client.client &.backfill
      head(success ? HTTP::Status::OK : HTTP::Status::INTERNAL_SERVER_ERROR)
    end
  end
end
