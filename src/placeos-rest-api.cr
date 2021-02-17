require "action-controller/logger"
require "secrets-env"
require "log_helper"

require "./placeos-rest-api/controllers/application"
require "./placeos-rest-api/controllers/*"

module PlaceOS::Api
  APP_NAME    = "rest-api"
  API_VERSION = "v2"
  # Calculate version, build time, commit at compile time
  VERSION        = {{ system(%(shards version "#{__DIR__}")).chomp.stringify.downcase }}
  BUILD_TIME     = {{ system("date -u").stringify }}
  BUILD_COMMIT   = {{ env("PLACE_COMMIT") || "DEV" }}
  CORE_NAMESPACE = "core"

  Log           = ::Log.for(APP_NAME)
  LOG_STDOUT    = ActionController.default_backend
  LOGSTASH_HOST = ENV["LOGSTASH_HOST"]?
  LOGSTASH_PORT = ENV["LOGSTASH_PORT"]?

  def self.log_backend
    if !(logstash_host = LOGSTASH_HOST.presence).nil?
      logstash_port = LOGSTASH_PORT.try(&.to_i?) || abort("LOGSTASH_PORT is either malformed or not present in environment")

      # Logstash UDP Input
      logstash = UDPSocket.new
      logstash.connect logstash_host, logstash_port
      logstash.sync = false

      # debug at the broadcast backend level, however this will be filtered
      # by the bindings
      backend = ::Log::BroadcastBackend.new
      backend.append(LOG_STDOUT, :trace)
      backend.append(ActionController.default_backend(
        io: logstash,
        formatter: ActionController.json_formatter
      ), :trace)
      backend
    else
      LOG_STDOUT
    end
  end

  ETCD_HOST = ENV["ETCD_HOST"]? || "localhost"
  ETCD_PORT = (ENV["ETCD_PORT"]? || "2379").to_i

  # server defaults in `./app.cr`
  TRIGGERS_URI = URI.parse(ENV["TRIGGERS_URI"]? || "http://triggers:3000")

  PROD = ENV["SG_ENV"]? == "production"

  def self.production?
    PROD
  end
end
