PROD = ENV["SG_ENV"]? == "production"

# Application dependencies
require "action-controller"

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
  settings.logger = logger
  settings.etcd_host = ENV["ETCD_HOST"]? || "localhost"
  settings.etcd_port = (ENV["ETCD_PORT"]? || 2379).to_i
end

# Add handlers that should run before your application
ActionController::Server.before(
  HTTP::ErrorHandler.new(!PROD),
  ActionController::LogHandler.new(filters),
  HTTP::CompressHandler.new
)
