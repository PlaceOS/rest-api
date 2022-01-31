module PlaceOS::Api
  APP_NAME    = "rest-api"
  API_VERSION = "v2"

  # Calculate version, build time, commit at compile time
  VERSION      = {{ system(%(shards version "#{__DIR__}")).chomp.stringify.downcase }}
  BUILD_TIME   = {{ system("date -u").stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}

  CORE_NAMESPACE = "core"

  ETCD_HOST = ENV["ETCD_HOST"]? || "localhost"
  ETCD_PORT = (ENV["ETCD_PORT"]? || "2379").to_i

  CORE_HOST = ENV["CORE_HOST"]? || "core"
  CORE_PORT = (ENV["CORE_PORT"]? || "3000").to_i

  PLACE_DISPATCH_HOST = ENV["PLACE_DISPATCH_HOST"]? || "dispatch"
  PLACE_DISPATCH_PORT = (ENV["PLACE_DISPATCH_PORT"]? || "3000").to_i

  PLACE_SOURCE_HOST = ENV["PLACE_SOURCE_HOST"]? || "127.0.0.1"
  PLACE_SOURCE_PORT = (ENV["PLACE_SOURCE_PORT"]? || 3000).to_i

  # server defaults in `./app.cr`
  TRIGGERS_URI = URI.parse(ENV["TRIGGERS_URI"]? || "http://triggers:3000")

  PROD = ENV["SG_ENV"]?.try(&.downcase) == "production"
end
