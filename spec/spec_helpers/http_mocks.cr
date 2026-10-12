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

  # The chat completions path alone, so the image stub above (which matches
  # every api.openai.com POST) cannot swallow a map AI call. Only the first
  # matching stub is used, so register this before `signage_ai_vendor`.
  CHAT_COMPLETIONS = /api\.openai\.com\/v1\/chat\/completions/

  # Chat completions answering `content` verbatim. `requests` collects every
  # body the stub received, for assertions on what was sent.
  def self.map_ai_vendor(content : String, finish : String = "stop", requests : Array(JSON::Any)? = nil)
    WebMock
      .stub(:post, CHAT_COMPLETIONS)
      .to_return do |request|
        if requests
          requests << JSON.parse(WebMock.body(request).to_s)
        end

        body = {
          id:      "chatcmpl-spec",
          choices: [{message: {role: "assistant", content: content, refusal: nil}, finish_reason: finish}],
          usage:   {prompt_tokens: 1200, completion_tokens: 80, total_tokens: 1280},
        }.to_json

        HTTP::Client::Response.new(200, body, HTTP::Headers{"Content-Type" => "application/json"})
      end
  end

  # The model declining to answer, which the adapter maps to `Moderated`.
  def self.map_ai_vendor_refused
    body = {
      id:      "chatcmpl-spec",
      choices: [{message: {role: "assistant", content: nil, refusal: "I can't help with that."}, finish_reason: "stop"}],
      usage:   {prompt_tokens: 1200, completion_tokens: 10, total_tokens: 1210},
    }.to_json

    WebMock
      .stub(:post, CHAT_COMPLETIONS)
      .to_return(body: body, status: 200, headers: HTTP::Headers{"Content-Type" => "application/json"})
  end

  # The vendor never answering: the read timeout fires inside the client.
  def self.map_ai_vendor_timeout
    WebMock
      .stub(:post, CHAT_COMPLETIONS)
      .to_return do |_request|
        raise IO::TimeoutError.new("Read timed out")
      end
  end

  # Prose instead of the JSON asked for.
  def self.map_ai_vendor_garbage
    map_ai_vendor("I think the boardroom should be light blue, so I would change its fill.")
  end

  # The answer cut off at the output limit on the first call, whole on the second.
  def self.map_ai_vendor_cut_off(content : String, requests : Array(JSON::Any))
    WebMock
      .stub(:post, CHAT_COMPLETIONS)
      .to_return do |request|
        requests << JSON.parse(WebMock.body(request).to_s)
        cut = requests.size == 1
        body = {
          id:      "chatcmpl-spec",
          choices: [{message: {role: "assistant", content: cut ? "" : content, refusal: nil}, finish_reason: cut ? "length" : "stop"}],
          usage:   {prompt_tokens: 1200, completion_tokens: 80, total_tokens: 1280},
        }.to_json
        HTTP::Client::Response.new(200, body, HTTP::Headers{"Content-Type" => "application/json"})
      end
  end

  # A 400 naming reasoning_effort on the first call, the answer on the second.
  def self.map_ai_vendor_no_reasoning(content : String, requests : Array(JSON::Any))
    WebMock
      .stub(:post, CHAT_COMPLETIONS)
      .to_return do |request|
        parsed = JSON.parse(WebMock.body(request).to_s)
        requests << parsed
        if parsed["reasoning_effort"]?
          error = {error: {message: "Unsupported parameter: 'reasoning_effort' is not supported with this model.", type: "invalid_request_error", param: "reasoning_effort", code: "unsupported_parameter"}}.to_json
          HTTP::Client::Response.new(400, error, HTTP::Headers{"Content-Type" => "application/json"})
        else
          body = {
            id:      "chatcmpl-spec",
            choices: [{message: {role: "assistant", content: content, refusal: nil}, finish_reason: "stop"}],
            usage:   {prompt_tokens: 1200, completion_tokens: 80, total_tokens: 1280},
          }.to_json
          HTTP::Client::Response.new(200, body, HTTP::Headers{"Content-Type" => "application/json"})
        end
      end
  end

  # The object store a generated candidate is written to and read back from.
  # Both verbs are signed URLs against the storage provider's host.
  #
  # The read is streamed (`Http.get_bytes` takes the response in a block), and
  # WebMock hands a stubbed response to that block as-is, so it carries a
  # `body_io` rather than a `body` string.
  def self.signage_ai_storage
    object_store = /amazonaws\.com|blob\.core\.windows\.net/

    WebMock.stub(:put, object_store).to_return(body: "", status: 200)

    WebMock
      .stub(:get, object_store)
      .to_return do |_request|
        HTTP::Client::Response.new(
          200,
          headers: HTTP::Headers{"Content-Type" => "image/jpeg"},
          body_io: IO::Memory.new(::Base64.decode(TINY_JPEG)),
        )
      end
  end
end
