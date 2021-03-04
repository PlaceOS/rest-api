class PlaceOS::Driver; end

# Application dependencies
require "action-controller"
require "placeos-log-backend"
# Application code
require "./placeos-rest-api"
# Server required after application controllers
require "action-controller/server"

module PlaceOS::Api
  # Logging configuration
  log_level = Api.production? ? ::Log::Severity::Info : ::Log::Severity::Debug
  log_backend = PlaceOS::LogBackend.log_backend
  ::Log.setup "*", :warn, log_backend
  ::Log.builder.bind "action-controller.*", log_level, log_backend
  ::Log.builder.bind "place_os.*", log_level, log_backend

  # Extra verbose coordination logging
  if ENV["PLACE_VERBOSE_CLUSTERING"]?.presence
    ::Log.builder.bind "hound_dog.*", ::Log::Severity::Debug, log_backend
    ::Log.builder.bind "clustering.*", ::Log::Severity::Debug, log_backend
  end

  # Configure Service discovery
  HoundDog.configure do |settings|
    settings.etcd_host = Api::ETCD_HOST
    settings.etcd_port = Api::ETCD_PORT
  end

  filters = ["bearer_token", "secret", "password"]

  # Add handlers that should run before your application
  ActionController::Server.before(
    ActionController::ErrorHandler.new(Api.production?, ["X-Request-ID"]),
    ActionController::LogHandler.new(filters, ms: true)
  )
end
