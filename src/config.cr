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
  settings.etcd_host = ENV["ETCD_HOST"]? || "localhost"
  settings.etcd_port = (ENV["ETCD_PORT"]? || 2379).to_i
end

PROD = ENV["SG_ENV"]? == "production"
filters = ["bearer_token", "secret", "password"]

# Add handlers that should run before your application
ActionController::Server.before(
  ActionController::ErrorHandler.new(PROD, ["X-Request-ID"]),
  ActionController::LogHandler.new(PROD ? filters : nil)
)

# Logging configuration
log_level = PROD ? Log::Severity::Info : Log::Severity::Debug
Log.builder.bind "*", log_level, PlaceOS::Api::LOG_BACKEND
Log.builder.bind "action-controller.*", log_level, PlaceOS::Api::LOG_BACKEND
Log.builder.bind "rest-api.*", log_level, PlaceOS::Api::LOG_BACKEND
