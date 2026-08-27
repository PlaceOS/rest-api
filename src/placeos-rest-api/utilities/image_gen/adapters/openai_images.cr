require "http/formdata"
require "json"

module PlaceOS::Api::ImageGen::Adapters
  # OpenAI's image API, and Azure OpenAI, which speaks the same request and
  # response shape at a different base URL with a different auth header.
  #
  # gpt-image-2 wants both edges to be a multiple of 16, returns base64 in
  # `data[].b64_json`, and can return every candidate from one call, so a
  # request of n candidates costs one vendor call.
  class OpenAIImages < Adapter
    DEFAULT_MODEL   = "gpt-image-2"
    DEFAULT_BASE    = "https://api.openai.com/v1"
    DEFAULT_VERSION = "2026-04-01-preview"

    MODELS = [
      ModelCapabilities.new(
        id: "gpt-image-2",
        name: "GPT Image 2",
        max_references: 16,
      ),
    ]

    def capabilities : ProviderCapabilities
      ProviderCapabilities.new(
        id: row.id.to_s,
        name: row.name,
        provider: row.provider.to_s,
        models: allowed(MODELS),
        default_model: row.default_model || DEFAULT_MODEL,
        region: row.location,
      )
    end

    def images_per_call : Int32
      MAX_CANDIDATES
    end

    def generate(request : AdapterRequest) : Array(AdapterImage)
      body = {
        model:         request.model,
        prompt:        request.prompt,
        n:             request.candidates,
        size:          request.size,
        quality:       quality(request.quality),
        output_format: "jpeg",
        moderation:    "auto",
      }.to_json

      post("images/generations", body, "application/json")
    end

    def edit(request : AdapterRequest) : Array(AdapterImage)
      source = request.source
      raise Error::ImageGen::Vendor.new("an edit needs a source image") if source.nil?

      io = IO::Memory.new
      content_type = ""
      HTTP::FormData.build(io) do |form|
        content_type = form.content_type
        form.field("model", request.model)
        form.field("prompt", request.prompt)
        form.field("n", request.candidates.to_s)
        form.field("size", request.size)
        form.field("quality", quality(request.quality))
        form.field("output_format", "jpeg")

        # the image being edited goes first, references after it
        add_image(form, source, "source")
        request.references.each_with_index do |reference, index|
          add_image(form, reference, "reference-#{index}")
        end
      end

      post("images/edits", io.to_s, content_type)
    end

    private def add_image(form : HTTP::FormData::Builder, reference : Reference, name : String) : Nil
      metadata = HTTP::FormData::FileMetadata.new(filename: "#{name}.#{extension(reference.mime)}")
      headers = HTTP::Headers{"Content-Type" => reference.mime}
      form.file("image[]", IO::Memory.new(reference.bytes), metadata, headers)
    end

    private def extension(mime : String) : String
      case mime
      when "image/png"  then "png"
      when "image/webp" then "webp"
      else                   "jpg"
      end
    end

    # "standard" is the vendor's medium tier, which is what the crowd
    # leaderboards rank first and what iteration runs at. "high" is the
    # explicit enhance step.
    private def quality(value : String) : String
      value == "high" ? "high" : "medium"
    end

    private def azure? : Bool
      row.provider.azure_openai?
    end

    private def base : String
      if (endpoint = row.endpoint.presence)
        endpoint.rstrip('/')
      elsif azure?
        raise Error::ImageGen::NotConfigured.new("Azure OpenAI provider #{row.name} needs an endpoint")
      else
        DEFAULT_BASE
      end
    end

    private def url_for(path : String) : URI
      if azure?
        deployment = credential("deployment")
        version = credentials["api_version"]?.try(&.as_s?) || DEFAULT_VERSION
        URI.parse("#{base}/openai/deployments/#{deployment}/#{path}?api-version=#{version}")
      else
        URI.parse("#{base}/#{path}")
      end
    end

    private def headers(content_type : String) : HTTP::Headers
      headers = HTTP::Headers{"Content-Type" => content_type}
      if azure?
        headers["api-key"] = credential("api_key")
      else
        headers["Authorization"] = "Bearer #{credential("api_key")}"
        if organisation = credentials["organisation"]?.try(&.as_s?).presence
          headers["OpenAI-Organization"] = organisation
        end
      end
      headers
    end

    private def post(path : String, body : String, content_type : String) : Array(AdapterImage)
      uri = url_for(path)
      response = Http.client(uri) do |client|
        client.post(uri.request_target, headers: headers(content_type), body: body)
      end

      raise_for_status(response)
      parse(response.body)
    end

    private def raise_for_status(response : HTTP::Client::Response) : Nil
      return if response.success?

      code = nil
      message = nil
      begin
        error = JSON.parse(response.body)["error"]?
        code = error.try(&.["code"]?).try(&.as_s?)
        message = error.try(&.["message"]?).try(&.as_s?)
      rescue JSON::ParseException
      end

      if code == "moderation_blocked" || code == "content_policy_violation"
        raise Error::ImageGen::Moderated.new(message || "the request was blocked by the vendor's safety system")
      end

      if response.status_code == 429
        raise Error::ImageGen::Busy.new(message || "the vendor is rate limiting this account")
      end

      raise Error::ImageGen::Vendor.new(message || vendor_message(response.body))
    end

    private def parse(body : String) : Array(AdapterImage)
      payload = JSON.parse(body)

      cost = payload["usage"]?.try(&.["total_tokens"]?).try(&.as_i64?).try(&.to_f)
      images = payload["data"]?.try(&.as_a?)
      raise Error::ImageGen::Vendor.new("no images in the vendor response") if images.nil? || images.empty?

      per_image = cost ? cost / images.size : nil

      images.compact_map do |entry|
        encoded = entry["b64_json"]?.try(&.as_s?)
        next nil unless encoded
        bytes = Base64.decode(encoded)
        dimensions = Http.dimensions(bytes)
        AdapterImage.new(
          bytes: bytes,
          mime: "image/jpeg",
          width: dimensions.try(&.[0]),
          height: dimensions.try(&.[1]),
          cost_units: per_image,
        )
      end
    end
  end
end
