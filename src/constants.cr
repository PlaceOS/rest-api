module ACAEngine::Api
  APP_NAME    = "ACAEngine REST API"
  API_VERSION = "v2"
  # calculate version at compile time
  VERSION        = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  CORE_NAMESPACE = "core"
end
