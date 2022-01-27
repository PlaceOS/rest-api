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

  PLACE_DISPATCH_HOST = ENV["PLACE_DISPATCH_HOST"]? || "dispatch"
  PLACE_DISPATCH_PORT = (ENV["PLACE_DISPATCH_PORT"]? || "3000").to_i

  PLACE_SOURCE_HOST = ENV["PLACE_SOURCE_HOST"]? || "127.0.0.1"
  PLACE_SOURCE_PORT = (ENV["PLACE_SOURCE_PORT"]? || 3000).to_i

  # server defaults in `./app.cr`
  TRIGGERS_URI = URI.parse(ENV["TRIGGERS_URI"]? || "http://triggers:3000")

  PROD = ENV["SG_ENV"]?.try(&.downcase) == "production"

  # CHANGELOG
  #################################################################################################

  CHANGELOG_URI = "https://raw.githubusercontent.com/PlaceOS/PlaceOS/nightly/CHANGELOG.md"

  PLATFORM_VERSION = {{ (env("PLACE_VERSION") || "DEV").lchop(PLACE_TAG_PREFIX) }}

  private PLACE_TAG_PREFIX = "placeos-"
  private BUILD_CHANGELOG = {{ !PLATFORM_VERSION.downcase.starts_with?("dev") }}

  PLATFORM_CHANGELOG = fetch_platform_changelog(BUILD_CHANGELOG)

  macro fetch_platform_changelog(build)
    {% if build %}
      {{ system("curl --location #{CHANGELOG_URI}").stringify }}
    {% else %}
      "CHANGELOG is not generated for development builds"
    {% end %}
  end
end
