class PlaceOS::Driver; end

# Application dependencies
require "action-controller"

# Application code
require "./logging"
require "./placeos-rest-api"

require "opentelemetry-instrumentation"
require "opentelemetry-instrumentation/src/opentelemetry/instrumentation/**"

# Server required after application controllers
require "action-controller/server"

module PlaceOS::Api
  # Configure Service discovery
  HoundDog.configure do |settings|
    settings.etcd_host = Api::ETCD_HOST
    settings.etcd_port = Api::ETCD_PORT
  end

  filters = ["bearer_token", "secret", "password", "api-key"]

  # Add handlers that should run before your application
  ActionController::Server.before(
    ActionController::ErrorHandler.new(Api.production?, ["X-Request-ID"]),
    Raven::ActionController::ErrorHandler.new,
    ActionController::LogHandler.new(filters, ms: true)
  )

  if api_key = NEW_RELIC_KEY
    OpenTelemetry.configure do |config|
      config.service_name = "PlaceOS Rest-API"
      config.service_version = "1.0.0"
      config.exporter = OpenTelemetry::Exporter.new(variant: :http) do |exporter|
        exporter = exporter.as(OpenTelemetry::Exporter::Http)
        exporter.endpoint = "https://otlp.nr-data.net:4318/v1/traces"
        headers = HTTP::Headers.new
        headers["api-key"] = api_key
        exporter.headers = headers
      end
    end
  end
end
