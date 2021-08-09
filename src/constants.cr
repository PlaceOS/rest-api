module PlaceOS::Api
  APP_NAME    = "rest-api"
  API_VERSION = "v2"

  # Calculate version, build time, commit at compile time
  VERSION      = {{ system(%(shards version "#{__DIR__}")).chomp.stringify.downcase }}
  BUILD_TIME   = {{ system("date -u").stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}

  CORE_NAMESPACE = "core"

  PROD = ENV["SG_ENV"]?.try(&.downcase) == "production"

  # Service Configuration

  ETCD_HOST = ENV["ETCD_HOST"]? || "localhost"
  ETCD_PORT = (ENV["ETCD_PORT"]? || "2379").to_i

  # PlaceOS Service Configuration

  PLACE_DISPATCH_HOST = (ENV["PLACEOS_DISPATCH_HOST"]? || ENV["PLACE_DISPATCH_HOST"]?).presence || "dispatch"
  PLACE_DISPATCH_PORT = (ENV["PLACEOS_DISPATCH_PORT"]? || ENV["PLACE_DISPATCH_PORT"]?).presence.try &.to_i || 3000

  PLACE_SOURCE_HOST = (ENV["PLACEOS_SOURCE_HOST"]? || ENV["PLACE_SOURCE_HOST"]?).presence || "source"
  PLACE_SOURCE_PORT = (ENV["PLACEOS_SOURCE_PORT"]? || ENV["PLACE_SOURCE_PORT"]?).presence.try &.to_i || 3000

  PLACE_BUILD_HOST = ENV["PLACEOS_BUILD_HOST"]?.presence || "build"
  PLACE_BUILD_PORT = ENV["PLACEOS_BUILD_PORT"]?.presence.try &.to_i? || 3000

  PLACE_BUILD_URI = URI.parse("http://#{BUILD_HOST}:#{BUILD_PORT}")

  PLACE_TRIGGERS_URI = URI.parse(ENV["PLACEOS_TRIGGERS_URI"]?.presence || ENV["TRIGGERS_URI"]?.presence || "http://triggers:3000")
end
