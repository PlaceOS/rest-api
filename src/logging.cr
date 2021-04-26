require "placeos-log-backend"

module PlaceOS::Api
  # Logging configuration
  log_backend = PlaceOS::LogBackend.log_backend
  log_level = Api.production? ? ::Log::Severity::Info : ::Log::Severity::Debug

  ::Log.setup "*", :warn, log_backend

  namespaces = ["action-controller.*", "place_os.*"]
  namespaces.each do |namespace|
    ::Log.builder.bind(namespace, log_level, log_backend)
  end

  # Extra verbose coordination logging
  if ENV["PLACE_VERBOSE_CLUSTERING"]?.presence
    ::Log.builder.bind "hound_dog.*", ::Log::Severity::Debug, log_backend
    ::Log.builder.bind "clustering.*", ::Log::Severity::Debug, log_backend
  end

  PlaceOS::LogBackend.register_severity_switch_signals(
    production: Api.production?,
    namespaces: namespaces,
    backend: log_backend,
  )
end
