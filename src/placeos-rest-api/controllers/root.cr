require "./application"
require "../utilities/core_discovery"

require "rethinkdb"
require "rethinkdb-orm"
require "search-ingest/client"
require "placeos-frontend-loader/client"

require "placeos-models/version"
require "uri"

module PlaceOS::Api
  class Root < Application
    base "/api/engine/v2/"

    before_action :check_admin, except: [:root, :healthz, :version, :signal, :cluster_version, :scopes, :mqtt_user, :mqtt_access]
    before_action :can_write_guest, only: [:signal]

    # Healthcheck
    ###############################################################################################

    get "/", :root do
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

    ###############################################################################################

    get "/version", :version do
      render json: Root.version
    end

    get "/cluster/versions", :cluster_version do
      render json: Root.construct_versions
    end

    get "/cluster/versions", :cluster_version do
      render json: Root.construct_versions
    end

    # NOTE: Lazy getter ensures SCOPES array is referenced after all scopes have been appended
    class_getter(scopes) { SCOPES }

    get "/scopes", :scopes do
      render json: Root.scopes
    end

    protected def mqtt_parse_token
      token = acquire_token
      raise Error::Unauthorized.new unless token
      begin
        @user_token = user_token = Model::UserJWT.decode(token)
      rescue e : JWT::Error
        Log.warn(exception: e) { {message: "bearer malformed", action: "mqtt_access"} }
        # Request bearer was malformed
        raise Error::Unauthorized.new "bearer malformed"
      end
    ensure
      set_user_id
    end

    # For MQTT JWT access: https://github.com/iegomez/mosquitto-go-auth#remote-mode
    # jwt_response_mode: status, jwt_params_mode: form
    post "/mqtt_user", :mqtt_user do
      user_token = mqtt_parse_token
      head :ok
    end

    # Sends a form with the following params: topic, clientid, acc (1: read, 2: write, 3: readwrite, 4: subscribe)
    post "/mqtt_access", :mqtt_access do
      user_token = mqtt_parse_token
      client = params["clientid"]
      topic = params["topic"]
      acc = params["acc"]
      response = HTTP::Status::FORBIDDEN
      error = nil

      Log.context.set(
        mqtt_client: client,
        mqtt_topic: topic,
        mqtt_access: acc
      )

      case acc
      when "1", "4" # read
        response = HTTP::Status::OK
      when "2", "3" # write
        unless is_support?
          error = "no write permissions"
        end
      else
        error = "unknown access level requested: #{acc}"
      end

      Log.warn { error.to_s } if error
      head response
    end

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
    post "/signal", :signal do
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

    post "/reindex", :reindex do
      success = SearchIngest::Client.client &.reindex(backfill: backfill?)
      head(success ? HTTP::Status::OK : HTTP::Status::INTERNAL_SERVER_ERROR)
    end

    post "/backfill", :backfill do
      success = SearchIngest::Client.client &.backfill
      head(success ? HTTP::Status::OK : HTTP::Status::INTERNAL_SERVER_ERROR)
    end
  end
end
