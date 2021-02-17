# FIXME: Hack to allow resolution of PlaceOS::Driver class/module
module PlaceOS; end

class PlaceOS::Driver; end

# Application dependencies
require "action-controller"

# Logging configuration
log_level = PlaceOS::Api.production? ? Log::Severity::Info : Log::Severity::Debug
log_backend = PlaceOS::Api.log_backend
::Log.setup "*", :warn, log_backend
::Log.builder.bind "action-controller.*", log_level, log_backend
::Log.builder.bind "rest-api.*", log_level, log_backend

# Extra verbose coordination logging
if ENV["PLACE_VERBOSE_CLUSTERING"]?.presence
  ::Log.builder.bind "hound_dog.*", Log::Severity::Debug, PlaceOS::Api::LOG_STDOUT
  ::Log.builder.bind "clustering.*", Log::Severity::Debug, PlaceOS::Api::LOG_STDOUT
end

# Application code
require "./placeos-rest-api"

# Server required after application controllers
require "action-controller/server"

# Configure Service discovery
HoundDog.configure do |settings|
  settings.etcd_host = PlaceOS::Api::ETCD_HOST
  settings.etcd_port = PlaceOS::Api::ETCD_PORT
end

filters = ["bearer_token", "secret", "password"]

# Add handlers that should run before your application
ActionController::Server.before(
  ActionController::ErrorHandler.new(PlaceOS::Api.production?, ["X-Request-ID"]),
  ActionController::LogHandler.new(filters, ms: true)
)
