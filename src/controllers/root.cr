require "./application"

module ACAEngine::Api
  class Root < Application
    base "/api/engine/v2/"

    before_action :check_admin, except: [:root, :healthz, :version]

    get "/", :root do
      head :ok
    end

    get "/healthz", :healthz do
      head :ok
    end

    get "/version", :version do
      render json: {
        app:     APP_NAME,
        version: VERSION,
      }
    end

    post "/reindex", :reindex do
      response = HTTP::Client.post(
        "http://rubber-soul:3000/api/rubber-soul/v1/reindex?backfill=#{params["backfill"]? == "true"}",
        headers: HTTP::Headers{"X-Request-ID" => logger.request_id || UUID.random.to_s},
      )
      head response.status_code
    end

    post "/backfill", :backfill do
      response = HTTP::Client.post(
        "http://rubber-soul:3000/api/rubber-soul/v1/backfill",
        headers: HTTP::Headers{"X-Request-ID" => logger.request_id || UUID.random.to_s},
      )
      head response.status_code
    end
  end
end
