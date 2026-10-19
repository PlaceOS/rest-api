module PlaceOS::Api
  APP_NAME    = "rest-api"
  API_VERSION = "v2"

  Log = ::Log.for(self)

  # Calculate version, build time, commit at compile time
  VERSION      = {{ system(%(shards version "#{__DIR__}")).chomp.stringify.downcase }}
  BUILD_TIME   = {{ system("date -u").stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}

  PLACE_DISPATCH_HOST = ENV["PLACE_DISPATCH_HOST"]? || "dispatch"
  PLACE_DISPATCH_PORT = (ENV["PLACE_DISPATCH_PORT"]? || "3000").to_i

  PLACE_SOURCE_HOST = ENV["PLACE_SOURCE_HOST"]? || "source"
  PLACE_SOURCE_PORT = (ENV["PLACE_SOURCE_PORT"]? || 3000).to_i

  INFLUX_API_KEY = ENV["INFLUX_API_KEY"]?
  INFLUX_HOST    = ENV["INFLUX_HOST"]?
  INFLUX_ORG     = ENV["INFLUX_ORG"]? || "placeos"

  # https://developer.mozilla.org/en-US/docs/Web/API/RTCIceServer
  WEBRTC_DEFAULT_ICE_CONFIG = ENV["WEBRTC_DEFAULT_ICE_CONFIG"]? || {urls: "stun:stun.l.google.com:19302"}.to_json

  # Signage AI image generation
  ####################################################################################################

  # concurrent vendor image calls per replica; a request that cannot reserve a slot
  # for every candidate is told the service is busy rather than queued
  SIGNAGE_AI_MAX_CALLS = (ENV["SIGNAGE_AI_MAX_CALLS"]? || "6").to_i

  # how long to wait on a single vendor call
  SIGNAGE_AI_READ_TIMEOUT = (ENV["SIGNAGE_AI_READ_TIMEOUT"]? || "180").to_i.seconds

  # unclaimed candidates and references are swept after this long
  SIGNAGE_AI_RETENTION = (ENV["SIGNAGE_AI_RETENTION_HOURS"]? || "48").to_i.hours

  # a job still running after this is treated as abandoned by a departed replica
  SIGNAGE_AI_JOB_STALE = (ENV["SIGNAGE_AI_JOB_STALE_MINUTES"]? || "10").to_i.minutes

  # kill switch: capabilities reports disabled and generate returns 503
  SIGNAGE_AI_DISABLED = ENV["SIGNAGE_AI_DISABLED"]?.try(&.downcase) == "true"

  # default quotas, overridden per provider row
  # The largest source or reference image we will pull into the process. The
  # whole object is read into memory and the Vertex adapter base64 encodes it,
  # so this bounds roughly twice this much per candidate in flight.
  SIGNAGE_AI_MAX_IMAGE_BYTES = (ENV["SIGNAGE_AI_MAX_IMAGE_MB"]? || "20").to_i64 * 1024 * 1024

  # And what every attachment on one request may come to together: the
  # per-image ceiling alone still allows eight of them at once.
  SIGNAGE_AI_MAX_REQUEST_BYTES = (ENV["SIGNAGE_AI_MAX_REQUEST_MB"]? || "48").to_i64 * 1024 * 1024

  SIGNAGE_AI_USER_PER_DAY     = (ENV["SIGNAGE_AI_USER_PER_DAY"]? || "60").to_i
  SIGNAGE_AI_DOMAIN_PER_MONTH = (ENV["SIGNAGE_AI_DOMAIN_PER_MONTH"]? || "2000").to_i

  # Map AI editing (text/vision calls against the same provider rows)
  ####################################################################################################

  # kill switch for map editing alone; SIGNAGE_AI_DISABLED turns both off
  MAP_AI_DISABLED = SIGNAGE_AI_DISABLED || ENV["MAP_AI_DISABLED"]?.try(&.downcase) == "true"

  # concurrent vendor text calls per replica, separate from the image slots
  MAP_AI_MAX_CALLS = (ENV["MAP_AI_MAX_CALLS"]? || "4").to_i

  MAP_AI_READ_TIMEOUT = (ENV["MAP_AI_READ_TIMEOUT"]? || "180").to_i.seconds

  # the context JSON posted inline with an edit request (nginx's default body limit is 1MB)
  MAP_AI_MAX_CONTEXT_BYTES = (ENV["MAP_AI_MAX_CONTEXT_KB"]? || "512").to_i * 1024

  MAP_AI_MAX_INSTRUCTION_CHARS = (ENV["MAP_AI_MAX_INSTRUCTION_CHARS"]? || "4000").to_i

  # operations accepted from one answer; the rest are kept but flagged
  MAP_AI_MAX_OPS = (ENV["MAP_AI_MAX_OPS"]? || "80").to_i

  MAP_AI_MAX_OUTPUT_TOKENS = (ENV["MAP_AI_MAX_OUTPUT_TOKENS"]? || "12000").to_i

  # the second attempt's output budget after an answer cut off at MAP_AI_MAX_OUTPUT_TOKENS
  MAP_AI_RETRY_OUTPUT_TOKENS = (ENV["MAP_AI_RETRY_OUTPUT_TOKENS"]? || "24000").to_i

  # default quotas in calls, overridden per provider row by map_user_per_day
  # and map_domain_per_month
  MAP_AI_USER_PER_DAY     = (ENV["MAP_AI_USER_PER_DAY"]? || "40").to_i
  MAP_AI_DOMAIN_PER_MONTH = (ENV["MAP_AI_DOMAIN_PER_MONTH"]? || "1000").to_i

  # used when a provider row names no text_model
  MAP_AI_DEFAULT_OPENAI_MODEL    = ENV["MAP_AI_DEFAULT_OPENAI_MODEL"]? || "gpt-5.4-mini"
  MAP_AI_DEFAULT_VERTEX_MODEL    = ENV["MAP_AI_DEFAULT_VERTEX_MODEL"]? || "gemini-3.8-flash"
  MAP_AI_DEFAULT_ANTHROPIC_MODEL = ENV["MAP_AI_DEFAULT_ANTHROPIC_MODEL"]? || "claude-opus-5-5"
  MAP_AI_ANTHROPIC_EFFORT        = ENV["MAP_AI_ANTHROPIC_EFFORT"]? || "medium"

  # text models offered in the editor's picker besides the row's own, comma separated
  MAP_AI_OPENAI_MODELS    = (ENV["MAP_AI_OPENAI_MODELS"]? || "gpt-5.4-mini,gpt-6-luna,gpt-6.1-sol").split(',').map(&.strip).reject(&.empty?)
  MAP_AI_ANTHROPIC_MODELS = (ENV["MAP_AI_ANTHROPIC_MODELS"]? || "claude-opus-5-5,claude-fable-5-1,claude-sonnet-5-5,claude-haiku-5-5").split(',').map(&.strip).reject(&.empty?)

  # server defaults in `./app.cr`
  TRIGGERS_URI = URI.parse(ENV["TRIGGERS_URI"]? || "http://triggers:3000")

  PROD = ENV["SG_ENV"]?.try(&.downcase) == "production"

  # Open AI
  OPENAI_API_KEY    = ENV["OPENAI_API_KEY"]?
  OPENAI_API_BASE   = ENV["OPENAI_API_BASE"]? # Set this to Azure URL only if Azure OpenAI is used
  OPENAI_API_MODEL  = ENV["OPENAI_API_MODEL"]? || "gpt-5-mini"
  OPENAI_MAX_TOKENS = ENV["OPENAI_MAX_TOKENS"]?.try(&.to_i) || 400_000

  # Headless browser (browserless) used by `POST /uploads/screenshot`
  BROWSER_URI = URI.parse(ENV["BROWSER_URI"]? || "http://browser:3000")
  # defaults to the shared service secret, as dispatch uses
  BROWSER_TOKEN      = ENV["BROWSER_TOKEN"]?.presence || ENV["PLACE_SERVER_SECRET"]?.presence || ENV["SERVER_SECRET"]?.presence
  SCREENSHOT_TIMEOUT = (ENV["SCREENSHOT_TIMEOUT"]? || "45").to_i.seconds

  # Upload temporary links
  TEMP_LINK_MAX_MINUTES     = ENV["TEMP_LINK_MAX_MINUTES"]?.try(&.to_i) || 1440
  TEMP_LINK_DEFAULT_MINUTES = ENV["TEMP_LINK_DEFAULT_MINUTES"]?.try(&.to_i) || TEMP_LINK_MAX_MINUTES

  # PlaceOS Tenant App
  PLACE_APP_TENANT_ID     = ENV["PLACE_APP_TENANT_ID"]? || ""
  PLACE_APP_CLIENT_ID     = ENV["PLACE_APP_CLIENT_ID"]? || ""
  PLACE_APP_CLIENT_SECRET = ENV["PLACE_APP_CLIENT_SECRET"]? || ""

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

  class_getter? production : Bool = PROD
end
