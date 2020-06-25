# FIXME: Hack to allow resolution of PlaceOS::Driver class/module
module PlaceOS; end

class PlaceOS::Driver; end

# Application dependencies
require "action-controller"
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
  ActionController::LogHandler.new(filters)
)

# Logging configuration
log_level = PlaceOS::Api.production? ? Log::Severity::Info : Log::Severity::Debug
::Log.setup "*", log_level, PlaceOS::Api::LOG_BACKEND
::Log.builder.bind "action-controller.*", log_level, PlaceOS::Api::LOG_BACKEND
::Log.builder.bind "rest-api.*", log_level, PlaceOS::Api::LOG_BACKEND
