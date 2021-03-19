require "placeos-log-backend"

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
end
