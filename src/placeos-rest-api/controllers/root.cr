require "./application"
require "../utilities/core_discovery"

require "rethinkdb"
require "rethinkdb-orm"
require "rubber-soul/client"
require "placeos-frontends/client"

require "placeos-models/version"
require "uri"
require "promise"

module PlaceOS::Api
  class Root < Application
    base "/api/engine/v2/"

    before_action :check_admin, except: [:root, :healthz, :version, :signal, :rversion, :cversion]
    skip_action :check_oauth_scope, only: :signal

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

    get "/cluster/versions", :cversion do
      render json: Root.construct_versions
    end

    class_getter version : PlaceOS::Model::Version do
      PlaceOS::Model::Version.new(
        service: APP_NAME,
        commit: BUILD_COMMIT,
        version: VERSION,
        build_time: BUILD_TIME
      )
    end

    private SERVICES = %w(frontend rubber core triggers dispatch)

    def self.construct_versions : Array(PlaceOS::Model::Version)
      version_channel = Channel(PlaceOS::Model::Version?).new
      {% for service in SERVICES %}
        spawn do
          %version = begin
                      {{service.id}}_version
                    rescue
                      Log.warn { {service: {{ service }}, message: "failed to request version" }}
                      nil
                    end
          version_channel.send(%version)
          end
        
      {% end %}
      Array(PlaceOS::Model::Version?).new(SERVICES.size) do
        version_channel.receive
      end.compact
    end

    private def self.frontend_version : (PlaceOS::Model::Version | Nil)
      Frontends::Client.client(&.version)
    end

    private def self.rubber_version : (PlaceOS::Model::Version | Nil)
      RubberSoul::Client.client(&.version)
    end

    private def self.core_version : (PlaceOS::Model::Version | Nil)
      Core::Client.client(PLACE_URI, &.version)
    end

    private def self.triggers_version : (PlaceOS::Model::Version | Nil)
      trigger_uri = TRIGGERS_URI.dup
      trigger_uri.path = "/api/triggers/v2/version"
      response = HTTP::Client.get trigger_uri
      PlaceOS::Model::Version.from_json(response.body)
    end

    private def self.dispatch_version : (PlaceOS::Model::Version | Nil)
      response = HTTP::Client.get "#{PLACE_URI}/api/server/version"
      PlaceOS::Model::Version.from_json(response.body)
    end

    class SignalParams < Params
      attribute channel : String, presence: true
    end

    # Can be used in a similar manner to a webhook for drivers
    post "/signal", :signal do
      args = SignalParams.new(params).validate!
      channel = args.channel

      if user_token.scope.includes?("guest")
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

    post "/reindex", :reindex do
      RubberSoul::Client.client &.reindex(backfill: params["backfill"]? == "true")
      head :ok
    end

    post "/backfill", :backfill do
      RubberSoul::Client.client &.backfill
      head :ok
    end
  end
end
