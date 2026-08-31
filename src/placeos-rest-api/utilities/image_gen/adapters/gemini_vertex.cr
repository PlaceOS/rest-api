require "google"
require "json"

module PlaceOS::Api::ImageGen::Adapters
  # Gemini image models on Vertex.
  #
  # Only the Vertex path is supported: it is the channel that carries Google's
  # indemnity and its no training terms, which an AI Studio key does not, so a
  # row without a service account is refused rather than quietly downgraded.
  #
  # Sizes are an enum and a ratio rather than pixels, so an output is close to
  # the requested shape but not exact; callers crop. One image comes back per
  # call, and at 2K the response can carry more than one image part, of which
  # the last is the requested size.
  class GeminiVertex < Adapter
    DEFAULT_MODEL = "gemini-3.1-flash-image"
    DEFAULT_HOST  = "https://aiplatform.googleapis.com"
    SCOPE         = "https://www.googleapis.com/auth/cloud-platform"

    # Google's image models are served from the global endpoint only. Its own
    # docs say not to use that endpoint where the processing region matters.
    LOCATION = "global"

    MODELS = [
      ModelCapabilities.new(
        id: "gemini-3.1-flash-image",
        name: "Nano Banana 2",
        max_references: 10,
      ),
      ModelCapabilities.new(
        id: "gemini-3-pro-image",
        name: "Nano Banana Pro",
        max_references: 6,
      ),
    ]

    # The shard caches tokens in a process wide hash keyed on scope and subject
    # only, so two service accounts with the same scope would share an entry.
    # Key on the issuer as well.
    class Auth < Google::ServiceAuth
      private def token_lookup
        "#{@issuer}_#{super}"
      end
    end

    def capabilities : ProviderCapabilities
      ProviderCapabilities.new(
        id: row.id.to_s,
        name: row.name,
        provider: row.provider.to_s,
        models: allowed(MODELS),
        default_model: row.default_model || DEFAULT_MODEL,
        region: LOCATION,
      )
    end

    def images_per_call : Int32
      1
    end

    def generate(request : AdapterRequest) : Array(AdapterImage)
      call(build_parts(request), request)
    end

    def edit(request : AdapterRequest) : Array(AdapterImage)
      source = request.source
      raise Error::ImageGen::Vendor.new("an edit needs a source image") if source.nil?
      call(build_parts(request, source), request)
    end

    private def build_parts(request : AdapterRequest, source : Reference? = nil) : Array(JSON::Any)
      parts = [] of JSON::Any

      if source
        parts << inline(source)
      end
      request.references.each { |reference| parts << inline(reference) }
      parts << JSON::Any.new({"text" => JSON::Any.new(request.prompt)})

      parts
    end

    private def inline(reference : Reference) : JSON::Any
      JSON::Any.new({
        "inlineData" => JSON::Any.new({
          "mimeType" => JSON::Any.new(reference.mime),
          "data"     => JSON::Any.new(Base64.strict_encode(reference.bytes)),
        }),
      })
    end

    private def call(parts : Array(JSON::Any), request : AdapterRequest) : Array(AdapterImage)
      body = {
        contents: [
          {role: "user", parts: parts},
        ],
        generationConfig: {
          responseModalities: ["IMAGE"],
          imageConfig:        {
            aspectRatio:              request.aspect,
            imageSize:                image_size(request.quality),
            outputMimeType:           "image/jpeg",
            outputCompressionQuality: 90,
          },
        },
      }.to_json

      uri = url_for(request.model)
      response = Http.client(uri) do |client|
        client.post(uri.request_target, headers: headers, body: body)
      end

      raise_for_status(response)
      parse(response.body)
    end

    # 1K is a draft, everything else is 2K. 4K is not offered: the two open
    # regressions Google has on 2K and 4K image to image sit on this path.
    private def image_size(quality : String) : String
      quality == "draft" ? "1K" : "2K"
    end

    private def project : String
      credentials["project_id"]?.try(&.as_s?) || credential("project")
    end

    private def url_for(model : String) : URI
      host = row.endpoint.presence.try(&.rstrip('/')) || DEFAULT_HOST
      URI.parse("#{host}/v1/projects/#{project}/locations/#{LOCATION}/publishers/google/models/#{model}:generateContent")
    end

    private def headers : HTTP::Headers
      HTTP::Headers{
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer #{token}",
      }
    end

    # How long to wait for Google to hand back an access token.
    TOKEN_TIMEOUT = 20.seconds

    # The token call does not go through `Http.client`: it is made by the google
    # shard, which builds its own client with no timeout. It runs inside the
    # candidate fiber, holding a slot, so a hung call held that slot for the
    # life of the process. Bounding the wait here releases the slot even if the
    # request behind it never comes back.
    private def token : String
      issuer = credential("client_email")
      key = credential("private_key")

      channel = Channel(String | Exception).new(1)
      spawn(name: "vertex-token") do
        begin
          channel.send(Auth.new(issuer: issuer, signing_key: key, scopes: SCOPE).get_token.access_token)
        rescue ex
          channel.send(ex)
        end
      end

      select
      when result = channel.receive
        raise result if result.is_a?(Exception)
        result
      when timeout(TOKEN_TIMEOUT)
        raise Error::ImageGen::Vendor.new("timed out authenticating with Google")
      end
    rescue ex : Error::ImageGen
      raise ex
    rescue ex
      raise Error::ImageGen::NotConfigured.new("could not authenticate with Google: #{ex.message}")
    end

    private def raise_for_status(response : HTTP::Client::Response) : Nil
      return if response.success?

      message = nil
      status = nil
      begin
        error = JSON.parse(response.body)["error"]?
        message = error.try(&.["message"]?).try(&.as_s?)
        status = error.try(&.["status"]?).try(&.as_s?)
      rescue JSON::ParseException
      end

      raise Error::ImageGen::Busy.new(message || "Google is rate limiting this project") if response.status_code == 429
      raise Error::ImageGen::Moderated.new(message || "the request was blocked") if status == "PERMISSION_DENIED" && message.try(&.includes?("safety"))
      raise Error::ImageGen::Vendor.new(message || vendor_message(response.body))
    end

    private def parse(body : String) : Array(AdapterImage)
      payload = JSON.parse(body)

      if (reason = payload["promptFeedback"]?.try(&.["blockReason"]?).try(&.as_s?))
        raise Error::ImageGen::Moderated.new("the prompt was blocked (#{reason})")
      end

      candidate = payload["candidates"]?.try(&.as_a?).try(&.first?)
      raise Error::ImageGen::Vendor.new("no candidates in the vendor response") if candidate.nil?

      if (finish = candidate["finishReason"]?.try(&.as_s?))
        case finish
        when "IMAGE_SAFETY", "PROHIBITED_CONTENT", "SAFETY"
          raise Error::ImageGen::Moderated.new("the image was blocked by Google's safety system (#{finish})")
        end
      end

      parts = candidate["content"]?.try(&.["parts"]?).try(&.as_a?) || [] of JSON::Any

      # at 2K the response can carry more than one image part; the last is the
      # one at the requested size
      inline = parts.compact_map { |part| part["inlineData"]? || part["inline_data"]? }.last?
      raise Error::ImageGen::Vendor.new("no image in the vendor response") if inline.nil?

      encoded = inline["data"]?.try(&.as_s?)
      raise Error::ImageGen::Vendor.new("no image data in the vendor response") if encoded.nil?

      bytes = Base64.decode(encoded)
      dimensions = Http.dimensions(bytes)
      cost = payload["usageMetadata"]?.try(&.["totalTokenCount"]?).try(&.as_i64?).try(&.to_f)

      [AdapterImage.new(
        bytes: bytes,
        mime: Http.mime_of(bytes, inline["mimeType"]?.try(&.as_s?) || "image/jpeg"),
        width: dimensions.try(&.[0]),
        height: dimensions.try(&.[1]),
        vendor_id: payload["responseId"]?.try(&.as_s?),
        cost_units: cost,
      )]
    end
  end
end
