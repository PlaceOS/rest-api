module ACAEngine::Api
  APP_NAME       = "ACAEngine REST API"
  API_VERSION    = "v2"
  # calculate version at compile time
  VERSION        = {{ system("shards version").stringify.strip.downcase }}
  CORE_NAMESPACE = "core"
end
