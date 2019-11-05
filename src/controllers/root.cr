require "./application"

module ACAEngine::Api
  class Root < Application
    base "/api/engine/v2/"

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
  end
end
