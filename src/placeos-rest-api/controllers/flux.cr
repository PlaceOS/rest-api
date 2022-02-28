require "./application"

module PlaceOS::Api
  class Flux < Application
    include Utils::CoreHelper

    # use influxdb path for any existing influx clients
    base "/api/v2"

    post("/query", :query) do
      request_headers = request.headers
      proxy_headers = HTTP::Headers.new
      proxy_headers.add "Accept", request_headers["Accept"]? || "application/csv"
      proxy_headers.add "Content-Type", request_headers["Content-Type"]? || "application/vnd.flux"

      # stream the data
      flux_client.post "/query", proxy_headers, body do |result|
        response.status_code = result.status_code
        response.headers["Content-Type"] = result.headers["Content-Type"]
        IO.copy(result.body_io, response)
      end
      @render_called = true
    end

    getter flux_client : HTTP::Client do
      api_key = ENV["INFLUX_API_KEY"]
      org = ENV["INFLUX_ORG"]? || "placeos"
      connection = HTTP::Client.new ENV["INFLUX_HOST"]
      connection.before_request do |req|
        req.headers["Authorization"] = "Token #{api_key}"
        req.path = "/api/v2#{req.path}"
        req.query_params["org"] = org
      end
      connection
    end
  end
end
