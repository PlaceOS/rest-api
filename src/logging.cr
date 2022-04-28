require "placeos-log-backend"
require "raven"
require "raven/integrations/action-controller"

require "./constants"

module PlaceOS::Api::Logging
  ::Log.progname = APP_NAME

  standard_sentry = Raven::LogBackend.new
  comprehensive_sentry = Raven::LogBackend.new(capture_all: true)

  # Logging configuration
  log_backend = PlaceOS::LogBackend.log_backend
  log_level = Api.production? ? ::Log::Severity::Info : ::Log::Severity::Debug
  namespaces = ["action-controller.*", "place_os.*"]

  builder = ::Log.builder
  builder.bind("*", log_level, log_backend)
  namespaces.each do |namespace|
    builder.bind(namespace, log_level, log_backend)

    # Bind raven's backend
    builder.bind namespace, :info, standard_sentry
    builder.bind namespace, :warn, comprehensive_sentry
  end

  ::Log.setup_from_env(
    default_level: log_level,
    builder: builder,
    backend: log_backend
  )

  # Configure Sentry
  Raven.configure &.async=(true)

  PlaceOS::LogBackend.register_severity_switch_signals(
    production: Api.production?,
    namespaces: namespaces,
    backend: log_backend,
  )

  PlaceOS::LogBackend.configure_opentelemetry(
    service_name: APP_NAME,
    service_version: VERSION,
  )
end
