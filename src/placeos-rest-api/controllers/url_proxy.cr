require "./application"

module PlaceOS::Api
  class UrlProxy < Application
    base "/api/engine/v2/proxy"

    # no auth required, abuse protections are handled separately
    skip_action :authorize!
    skip_action :set_user_id

    # hop-by-hop headers are connection specific and must not be forwarded
    HOP_BY_HOP_HEADERS = {
      "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
      "te", "trailer", "transfer-encoding", "upgrade",
    }

    # `Host` is set by the HTTP client for the upstream URI and forwarding
    # `Cookie` would leak this domain's cookies to the remote server
    SKIP_REQUEST_HEADERS = HOP_BY_HOP_HEADERS + {"host", "cookie", "content-length"}

    # don't allow the remote server to set cookies on this domain
    SKIP_RESPONSE_HEADERS = HOP_BY_HOP_HEADERS + {"set-cookie"}

    # proxy the request to the provided URL, forwarding request headers
    # and streaming the remote content back to the client
    @[AC::Route::GET("/")]
    def proxy(
      @[AC::Param::Info(description: "the fully qualified URL to be proxied", example: "https://example.com/image.png")]
      url : String,
    ) : Nil
      uri = URI.parse(url) rescue nil
      unless uri && uri.scheme.in?({"http", "https"}) && uri.host.presence
        raise AC::Route::Param::ValueError.new("a fully qualified http(s) URL is required", "url")
      end

      headers = HTTP::Headers.new
      request.headers.each do |key, values|
        headers[key] = values unless SKIP_REQUEST_HEADERS.includes?(key.downcase)
      end

      @__render_called__ = true

      HTTP::Client.get(url, headers: headers) do |upstream_response|
        # Set the response status code
        response.status_code = upstream_response.status_code

        # Copy headers from the upstream response, excluding hop-by-hop headers
        upstream_response.headers.each do |key, value|
          response.headers[key] = value unless SKIP_RESPONSE_HEADERS.includes?(key.downcase)
        end

        # Stream the response body directly to the client
        if body_io = upstream_response.body_io?
          IO.copy(body_io, response)
        else
          response.print upstream_response.body
        end
      end
    end
  end
end
