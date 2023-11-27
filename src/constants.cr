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

  INFLUX_API_KEY = ENV["INFLUX_API_KEY"]?
  INFLUX_HOST    = ENV["INFLUX_HOST"]?
  INFLUX_ORG     = ENV["INFLUX_ORG"]? || "placeos"

  # https://developer.mozilla.org/en-US/docs/Web/API/RTCIceServer
  WEBRTC_DEFAULT_ICE_CONFIG = ENV["WEBRTC_DEFAULT_ICE_CONFIG"]? || {urls: "stun:stun.l.google.com:19302"}.to_json

  # server defaults in `./app.cr`
  TRIGGERS_URI = URI.parse(ENV["TRIGGERS_URI"]? || "http://triggers:3000")

  PROD = ENV["SG_ENV"]?.try(&.downcase) == "production"

  # Open AI
  OPENAI_API_KEY    = ENV["OPENAI_API_KEY"]?
  OPENAI_API_BASE   = ENV["OPENAI_API_BASE"]? # Set this to Azure URL only if Azure OpenAI is used
  OPENAI_API_MODEL  = ENV["OPENAI_API_MODEL"]? || "gpt-4"
  OPENAI_MAX_TOKENS = ENV["OPENAI_MAX_TOKENS"]?.try(&.to_i) || 8192

  # CHANGELOG
  #################################################################################################

  CHANGELOG_URI = "https://raw.githubusercontent.com/PlaceOS/PlaceOS/nightly/CHANGELOG.md"

  PLATFORM_VERSION = {{ (env("PLACE_VERSION") || "DEV").tr(PLACE_TAG_PREFIX, "") }}

  private PLACE_TAG_PREFIX = "placeos-"
  private BUILD_CHANGELOG  = {{ !PLATFORM_VERSION.downcase.starts_with?("dev") }}

  PLATFORM_CHANGELOG = fetch_platform_changelog(BUILD_CHANGELOG)

  macro fetch_platform_changelog(build)
    {% if build %}
      {{ system("curl --silent --location #{CHANGELOG_URI}").stringify }}
    {% else %}
      "CHANGELOG is not generated for development builds"
    {% end %}
  end
end
