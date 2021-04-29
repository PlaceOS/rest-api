require "placeos-log-backend"
require "raven"
require "raven/integrations/action-controller"

module PlaceOS::Api
  standard_sentry = Raven::LogBackend.new
  comprehensive_sentry = Raven::LogBackend.new(capture_all: true)

  # Logging configuration
  log_backend = PlaceOS::LogBackend.log_backend
  log_level = Api.production? ? ::Log::Severity::Info : ::Log::Severity::Debug
  namespaces = ["action-controller.*", "place_os.*"]

  ::Log.setup do |config|
    config.bind "*", :warn, log_backend

    namespaces.each do |namespace|
      config.bind namespace, log_level, log_backend

      # Bind raven's backend
      config.bind namespace, :info, standard_sentry
      config.bind namespace, :warn, comprehensive_sentry
    end

    # Extra verbose coordination logging
    if ENV["PLACE_VERBOSE_CLUSTERING"]?.presence
      config.bind "hound_dog.*", ::Log::Severity::Trace, log_backend
      config.bind "clustering.*", ::Log::Severity::Trace, log_backend
    end
  end

  # Configure Sentry
  Raven.configure &.async=(true)

  PlaceOS::LogBackend.register_severity_switch_signals(
    production: Api.production?,
    namespaces: namespaces,
    backend: log_backend,
  )
end
