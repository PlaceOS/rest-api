require "placeos-log-backend"
require "./constants"

module PlaceOS::Api::Logging
  ::Log.progname = APP_NAME

  # Logging configuration
  log_backend = PlaceOS::LogBackend.log_backend
  log_level = Api.production? ? ::Log::Severity::Info : ::Log::Severity::Debug
  namespaces = ["action-controller.*", "place_os.*"]

  builder = ::Log.builder
  builder.bind("*", log_level, log_backend)
  namespaces.each do |namespace|
    builder.bind(namespace, log_level, log_backend)
  end

  ::Log.setup_from_env(
    default_level: log_level,
    builder: builder,
    backend: log_backend
  )

  PlaceOS::LogBackend.register_severity_switch_signals(
    production: Api.production?,
    namespaces: namespaces,
    backend: log_backend,
  )
end
