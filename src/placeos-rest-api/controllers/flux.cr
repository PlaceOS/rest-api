require "./application"

module PlaceOS::Api
  class Flux < Application
    include Utils::CoreHelper

    # use influxdb path for any existing influx clients
    base "/api/v2"

    post("/query", :query) do
      request_headers = request.headers

      # stream the data
      flux_client.post "/query", HTTP::Headers{
        "Accept"       => request_headers["Accept"]? || "application/csv",
        "Content-Type" => request_headers["Content-Type"]? || "application/vnd.flux",
      }, body do |result|
        response.status_code = result.status_code
        response.headers["Content-Type"] = result.headers["Content-Type"]
        IO.copy(result.body_io, response)
      end

      @render_called = true
    end

    getter flux_client : HTTP::Client do
      api_key = INFLUX_API_KEY || raise("no Influx API key configured")
      org = INFLUX_ORG
      connection = HTTP::Client.new URI.parse(INFLUX_HOST || raise("no Influx hostname configured"))
      connection.before_request do |req|
        req.headers["Authorization"] = "Token #{api_key}"
        req.path = "/api/v2#{req.path}"
        req.query_params["org"] = org
      end
      connection
    end
  end
end
