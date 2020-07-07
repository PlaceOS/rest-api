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

  Log         = ::Log.for(APP_NAME)
  LOG_BACKEND = ActionController.default_backend

  ETCD_HOST = ENV["ETCD_HOST"]? || "localhost"
  ETCD_PORT = (ENV["ETCD_PORT"]? || "2379").to_i

  # server defaults in `./app.cr`
  TRIGGERS_URI = URI.parse(ENV["TRIGGERS_URI"] || "http://triggers:3000")

  PROD = ENV["SG_ENV"]? == "production"

  def self.production?
    PROD
  end
end
