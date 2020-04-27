module PlaceOS::Api
  APP_NAME       = "PlaceOS REST API"
  API_VERSION    = "v2"
  CORE_NAMESPACE = "core"
  # Calculate version, build time, commit at compile time
  VERSION      = {{ system(%(shards version "#{__DIR__}")).chomp.stringify.downcase }}
  BUILD_TIME   = {{ system("date -u").stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}
end
