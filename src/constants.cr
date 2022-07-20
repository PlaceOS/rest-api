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

  INFLUX_API_KEY = ENV["INFLUX_API_KEY"]?
  INFLUX_HOST    = ENV["INFLUX_HOST"]?
  INFLUX_ORG     = ENV["INFLUX_ORG"]? || "placeos"

  # CHANGELOG
  #################################################################################################

  CHANGELOG_URI = "https://raw.githubusercontent.com/PlaceOS/PlaceOS/nightly/CHANGELOG.md"

  PLATFORM_VERSION = {{ (env("PLACE_VERSION") || "DEV").tr(PLACE_TAG_PREFIX, "") }}

  private PLACE_TAG_PREFIX = "placeos-"
  private BUILD_CHANGELOG  = {{ !PLATFORM_VERSION.downcase.starts_with?("dev") }}

  PLATFORM_CHANGELOG = "" # fetch_platform_changelog(BUILD_CHANGELOG)

  macro fetch_platform_changelog(build)
    {% if build %}
      {{ system("curl --silent --location #{CHANGELOG_URI}").stringify }}
    {% else %}
      "CHANGELOG is not generated for development builds"
    {% end %}
  end
end
