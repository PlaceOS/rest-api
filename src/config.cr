# Application dependencies
require "action-controller"

# Allows request IDs to be configured for logging
# You can extend this with additional properties
class HTTP::Request
  property id : String?
  property user_id : String?
end

# Application code
require "./constants"
require "./controllers/application"
require "./controllers/*"

# Server required after application controllers
require "action-controller/server"

# Do not buffer logs
STDOUT.sync = true

# Configure Service discovery
HoundDog.configure do |settings|
  settings.logger = ActionController::Base.settings.logger
  settings.etcd_host = ENV["ETCD_HOST"]? || "localhost"
  settings.etcd_port = (ENV["ETCD_PORT"]? || 2379).to_i
end

PROD = ENV["SG_ENV"]? != "production"
FILTERS = PROD ? ["bearer_token", "secret"] : [] of String

# Add handlers that should run before your application
ActionController::Server.before(
  HTTP::ErrorHandler.new(PROD),
  ActionController::LogHandler.new(STDOUT, FILTERS) { |context|
    # Allows for custom tags to be included when logging
    # For example you might want to include a user id here.
    {
      request_id: context.request.id,      # `context.request.id` is set in `controllers/application`
      user_id:    context.request.user_id, # `context.request.user_id` is set in `utils/current_user`
    }.map { |key, value| " #{key}=#{value}" if value && !value.empty? }.compact.join("")
  },
  HTTP::CompressHandler.new
)
