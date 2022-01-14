require "webmock"

module PlaceOS::Api::HttpMocks
  def self.reset
    WebMock.reset
    WebMock.allow_net_connect = true
  end

  # Mock etcd response for core nodes request.
  # The primary request for core discovery.
  def self.etcd_range
    WebMock.stub(:post, "http://etcd:2379/v3/kv/range")
      .with(
        body: "{\"key\":\"c2VydmljZS9jb3JlLw==\",\"range_end\":\"c2VydmljZS9jb3JlMA==\"}",
        headers: {"Content-Type" => "application/json"}
      )
      .to_return(
        body: {
          count: "1",
          kvs:   [{
            key:   "c2VydmljZS9jb3JlLw==",
            value: Base64.strict_encode("http://127.0.0.1:9001"),
          }],
        }.to_json
      )
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
