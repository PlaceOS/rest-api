require "../helper"

module PlaceOS::Api
  describe UrlProxy do
    describe "GET /proxy" do
      it "proxies the content of the provided URL without requiring auth" do
        WebMock
          .stub(:get, "https://upstream.example.com/image.png")
          .to_return(
            status: 200,
            body: "image-data",
            headers: HTTP::Headers{
              "Content-Type" => "image/png",
              "ETag"         => %("abc123"),
            }
          )

        params = HTTP::Params{"url" => "https://upstream.example.com/image.png"}
        result = client.get("#{UrlProxy.base_route}?#{params}")

        result.status_code.should eq 200
        result.body.should eq "image-data"
        result.headers["Content-Type"].should eq "image/png"
        result.headers["ETag"].should eq %("abc123")
      end

      it "preserves the query string of the proxied URL" do
        WebMock
          .stub(:get, "https://upstream.example.com/data?key=value&other=1")
          .to_return(status: 200, body: "query-data")

        params = HTTP::Params{"url" => "https://upstream.example.com/data?key=value&other=1"}
        result = client.get("#{UrlProxy.base_route}?#{params}")

        result.status_code.should eq 200
        result.body.should eq "query-data"
      end

      it "forwards request headers, excluding connection specific headers" do
        WebMock
          .stub(:get, "https://upstream.example.com/echo")
          .to_return do |request|
            body = {
              authorization: request.headers["Authorization"]?,
              custom:        request.headers["X-Custom-Header"]?,
              cookie:        request.headers["Cookie"]?,
              host:          request.headers["Host"]?,
            }.to_json
            HTTP::Client::Response.new(200, body, HTTP::Headers{"Content-Type" => "application/json"})
          end

        headers = HTTP::Headers{
          "Authorization"   => "Bearer upstream-token",
          "X-Custom-Header" => "custom-value",
          "Cookie"          => "session=secret",
        }
        params = HTTP::Params{"url" => "https://upstream.example.com/echo"}
        result = client.get("#{UrlProxy.base_route}?#{params}", headers: headers)

        result.status_code.should eq 200
        seen = JSON.parse(result.body)
        seen["authorization"].should eq "Bearer upstream-token"
        seen["custom"].should eq "custom-value"
        # cookies for this domain must not leak to the remote server
        seen["cookie"].raw.should be_nil
        # Host must be that of the upstream URI, not this service
        seen["host"].should eq "upstream.example.com"
      end

      it "returns the upstream status code" do
        WebMock
          .stub(:get, "https://upstream.example.com/missing")
          .to_return(status: 404, body: "not found")

        params = HTTP::Params{"url" => "https://upstream.example.com/missing"}
        result = client.get("#{UrlProxy.base_route}?#{params}")

        result.status_code.should eq 404
        result.body.should eq "not found"
      end

      it "rejects URLs that are not fully qualified http(s) URLs" do
        ["ftp://example.com/file", "not a url", "/relative/path", "https://"].each do |bad_url|
          params = HTTP::Params{"url" => bad_url}
          result = client.get("#{UrlProxy.base_route}?#{params}")
          result.status_code.should eq 400
        end
      end

      it "requires the url param" do
        result = client.get(UrlProxy.base_route)
        result.status_code.should eq 422
      end
    end
  end
end
