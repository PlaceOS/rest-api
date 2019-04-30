require "./application"

module Engine::API
  class Root < Application
    base "/"

    get "/healthz", :healthz do
      head :ok
    end

    get "/version", :version do
      render json: {
        version: VERSION,
      }
    end
  end
end
