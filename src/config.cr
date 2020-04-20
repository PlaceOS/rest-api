# FIXME: Hack to allow resolution of PlaceOS::Driver class/module
module PlaceOS; end

class PlaceOS::Driver; end

# Application dependencies
require "action-controller"

PROD = ENV["SG_ENV"]? == "production"

# Logging configuration
ActionController::Logger.add_tag request_id
ActionController::Logger.add_tag user_id

logger = ActionController::Base.settings.logger
logger.level = PROD ? Logger::INFO : Logger::DEBUG
filters = PROD ? ["bearer_token", "secret", "password"] : [] of String

# Application code
require "./constants"
require "./controllers/application"
require "./controllers/*"

# Server required after application controllers
require "action-controller/server"

# Configure Service discovery
HoundDog.configure do |settings|
  settings.etcd_host = ENV["ETCD_HOST"]? || "localhost"
  settings.etcd_port = (ENV["ETCD_PORT"]? || 2379).to_i
end

# Add handlers that should run before your application
ActionController::Server.before(
  ActionController::ErrorHandler.new(!PROD, ["X-Request-ID"]),
  ActionController::LogHandler.new(filters)
)
