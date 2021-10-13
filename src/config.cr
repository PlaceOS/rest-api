class PlaceOS::Driver; end

# Application dependencies
require "action-controller"

# Application code
require "./logging"
require "./placeos-rest-api"

# Server required after application controllers
require "action-controller/server"

require "opentelemetry"

module PlaceOS::Api
  # Configure Service discovery
  HoundDog.configure do |settings|
    settings.etcd_host = Api::ETCD_HOST
    settings.etcd_port = Api::ETCD_PORT
  end

  OpenTelemetry.configure do |c|
    c.exporter = OpenTelemetry::BatchExporter.new(
      OpenTelemetry::HTTPExporter.new(
        endpoint: URI.parse("https://api.honeycomb.io"),
        headers: HTTP::Headers{
          # Get your Honeycomb API key from https://ui.honeycomb.io/account
          "x-honeycomb-team" => "XX",
          # Name this whatever you like. Honeycomb will create the dataset when it
          # begins reporting data.
          "x-honeycomb-dataset" => "XX",
        },
      )
    )
  end

  filters = ["bearer_token", "secret", "password", "api-key"]

  # Add handlers that should run before your application
  ActionController::Server.before(
    ActionController::ErrorHandler.new(Api.production?, ["X-Request-ID"]),
    Raven::ActionController::ErrorHandler.new,
    ActionController::LogHandler.new(filters, ms: true),
    OpenTelemetry::Middleware.new("http.server.request")
  )
end
