require "./application"

module Engine::API
  class Root < Application
    base "/"

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
