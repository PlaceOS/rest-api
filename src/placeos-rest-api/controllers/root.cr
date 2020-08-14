require "./application"

require "rubber-soul/client"

module PlaceOS::Api
  class Root < Application
    base "/api/engine/v2/"

    before_action :check_admin, except: [:root, :healthz, :version, :signal]

    get "/", :root do
      head :ok
    end

    get "/version", :version do
      render json: {
        app:        APP_NAME,
        version:    VERSION,
        commit:     BUILD_COMMIT,
        build_time: BUILD_TIME,
      }
    end

    # Can be used in a similar manner to a webhook for drivers
    post "/signal", :signal do
      channel = params["channel"]
      payload = if body = request.body
                  body.gets_to_end
                else
                  ""
                end

      ::PlaceOS::Driver::Storage.with_redis &.publish("placeos/#{channel}", payload)
      head :ok
    end

    post "/reindex", :reindex do
      RubberSoul::Client.client &.reindex(backfill: params["backfill"]? == "true")
      head :ok
    end

    post "/backfill", :backfill do
      RubberSoul::Client.client &.backfill
      head :ok
    end
  end
end
