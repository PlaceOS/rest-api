require "base64"
require "webmock"

module PlaceOS::Api::HttpMocks
  # A real 1x1 JPEG. The signage AI runner reads the mime type and the
  # dimensions straight out of the file header, so a vendor stub has to answer
  # with an image rather than arbitrary bytes.
  TINY_JPEG = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="

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

  # OpenAI's image API, answering with `TINY_JPEG`. `candidates` pins the number
  # of images returned; left out, the stub returns as many as the adapter asked
  # for, which is how the vendor behaves.
  #
  # Only the first matching stub is used, so a spec that wants a refusal must
  # register `signage_ai_vendor_refused` and not this one.
  def self.signage_ai_vendor(candidates : Int32? = nil)
    WebMock
      .stub(:post, /api\.openai\.com/)
      .to_return do |request|
        wanted = candidates
        if wanted.nil?
          wanted = begin
            JSON.parse(WebMock.body(request).to_s)["n"]?.try(&.as_i?) || 1
          rescue JSON::ParseException
            1
          end
        end

        body = {
          data:  Array.new(wanted) { {b64_json: TINY_JPEG} },
          usage: {total_tokens: 10 * wanted},
        }.to_json

        HTTP::Client::Response.new(200, body, HTTP::Headers{"Content-Type" => "application/json"})
      end
  end

  # The vendor blocking a prompt, which the adapter maps to `Moderated`.
  def self.signage_ai_vendor_refused
    body = {error: {code: "content_policy_violation", message: "the request was blocked"}}.to_json

    WebMock
      .stub(:post, /api\.openai\.com/)
      .to_return(body: body, status: 400, headers: HTTP::Headers{"Content-Type" => "application/json"})
  end

  # The object store a generated candidate is written to and read back from.
  # Both verbs are signed URLs against the storage provider's host.
  def self.signage_ai_storage
    object_store = /amazonaws\.com|blob\.core\.windows\.net/

    WebMock.stub(:put, object_store).to_return(body: "", status: 200)

    WebMock
      .stub(:get, object_store)
      .to_return do |_request|
        HTTP::Client::Response.new(
          200,
          String.new(::Base64.decode(TINY_JPEG)),
          HTTP::Headers{"Content-Type" => "image/jpeg"},
        )
      end
  end
end
