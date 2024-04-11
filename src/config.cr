class PlaceOS::Driver; end

# Application dependencies
require "action-controller"

# Application code
require "./logging"
require "./placeos-rest-api"
require "./telemetry"

# Server required after application controllers
require "action-controller/server"

module PlaceOS::Api
  filters = ["bearer_token", "secret", "password", "api-key"]

  # Add handlers that should run before your application
  ActionController::Server.before(
    ActionController::ErrorHandler.new(Api.production?, ["X-Request-ID"]),
    Raven::ActionController::ErrorHandler.new,
    ActionController::LogHandler.new(filters, ms: true)
  )
end
