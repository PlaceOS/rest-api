require "webmock"

module PlaceOS::Api::HttpMocks
  def self.reset
    WebMock.reset
    WebMock.allow_net_connect = true
  end

  def self.core_compiled
    WebMock
      .stub(:get, /\/api\/core\/v1\/drivers\/.*\/compiled/)
      .to_return(
        headers: HTTP::Headers{
          "Content-Type" => "application/json",
        },
        body: true.to_json
      )
  end

  # Generically construct a service version response based
  # on a well-formed service version request.
  def self.service_version
    version_endpoint = /(?!:6000).*\/api\/(?<service>[^\/]+)\/(?<version>[^\/]+)\/version/
    WebMock
      .stub(:get, version_endpoint)
      .to_return do |request|
        request.path =~ version_endpoint
        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json"
        body = {
          service:          $~["service"],
          commit:           "DEV",
          version:          "v1.0.0",
          build_time:       "Tue Jun 01 01:00:00 UTC 2021",
          platform_version: "DEV",
        }.to_json
        HTTP::Client::Response.new(200, body, headers)
      end
  end
end
