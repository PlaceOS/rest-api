require "./application"

require "rubber-soul/client"

module PlaceOS::Api
  class Root < Application
    base "/api/engine/v2/"

    before_action :check_admin, except: [:root, :healthz, :version, :signal]
    skip_action :check_oauth_scope, only: :signal

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

    class SignalParams < Params
      attribute channel : String, presence: true
    end

    # Can be used in a similar manner to a webhook for drivers
    post "/signal", :signal do
      args = SignalParams.new(params).validate!
      channel = args.channel

      if user_token.scope.includes?("guest")
        head :forbidden unless channel.includes?("/guest/")
      end

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
