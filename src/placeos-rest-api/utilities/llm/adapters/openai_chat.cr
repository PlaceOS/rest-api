require "base64"
require "json"

require "../../openai_vendor"

module PlaceOS::Api::Llm::Adapters
  # OpenAI Chat Completions, and Azure OpenAI, which speaks the same request and
  # response shape at a different base URL with a different auth header.
  #
  # On Azure the model id is the deployment name. An endpoint ending in
  # `/openai/v1` is the v1 API (no api-version); any other endpoint is the
  # legacy per-deployment URL with `credentials.api_version`.
  class OpenAIChat < Adapter
    include Utils::OpenAIVendor

    # the legacy Azure chat completions API version used when the row's
    # credentials name none
    DEFAULT_VERSION = "2024-10-21"

    def default_text_model : String
      MAP_AI_DEFAULT_OPENAI_MODEL
    end

    def known_text_models : Array(String)
      MAP_AI_OPENAI_MODELS
    end

    def complete(request : Request) : Result
      response = post(request.model, body_for(request, request.reasoning_effort))

      # a model that takes no reasoning_effort rejects the whole request naming
      # the parameter; sent again without it
      if response.status_code == 400 && request.reasoning_effort && response.body.includes?("reasoning_effort")
        response = post(request.model, body_for(request, nil))
      end

      raise_for_status(response)
      parse(response.body)
    rescue IO::TimeoutError
      raise Error::ImageGen::Timeout.new("the model did not answer within #{MAP_AI_READ_TIMEOUT.total_seconds.to_i} seconds")
    end

    private def body_for(request : Request, reasoning_effort : String?) : String
      content = request.parts.map do |part|
        case part
        in TextPart
          {type: "text", text: part.text}.to_json
        in ImagePart
          {
            type:      "image_url",
            image_url: {
              url:    "data:#{part.mime};base64,#{Base64.strict_encode(part.bytes)}",
              detail: part.detail,
            },
          }.to_json
        end
      end

      JSON.build do |json|
        json.object do
          json.field "model", request.model
          json.field "messages" do
            json.array do
              json.object do
                json.field "role", "system"
                json.field "content", request.system
              end
              json.object do
                json.field "role", "user"
                json.field "content" do
                  json.array do
                    content.each { |part| json.raw part }
                  end
                end
              end
            end
          end
          json.field "max_completion_tokens", request.max_output_tokens
          if (schema = request.schema)
            json.field "response_format" do
              json.object do
                json.field "type", "json_schema"
                json.field "json_schema" do
                  json.object do
                    json.field "name", request.schema_name
                    json.field "strict", true
                    json.field "schema" { schema.to_json(json) }
                  end
                end
              end
            end
          end
          json.field "reasoning_effort", reasoning_effort if reasoning_effort
        end
      end
    end

    private def url_for(model : String) : URI
      if azure? && !base.ends_with?("/openai/v1")
        version = credentials["api_version"]?.try(&.as_s?).presence || DEFAULT_VERSION
        URI.parse("#{base}/openai/deployments/#{model}/chat/completions?api-version=#{version}")
      else
        URI.parse("#{base}/chat/completions")
      end
    end

    private def post(model : String, body : String) : HTTP::Client::Response
      uri = url_for(model)
      ImageGen::Http.client(uri, MAP_AI_READ_TIMEOUT) do |client|
        client.post(uri.request_target, headers: openai_headers("application/json"), body: body)
      end
    end

    private def parse(body : String) : Result
      payload = begin
        JSON.parse(body)
      rescue JSON::ParseException
        raise Error::ImageGen::Vendor.new("the vendor response was not JSON")
      end

      choice = payload["choices"]?.try(&.as_a?).try(&.first?)
      raise Error::ImageGen::Vendor.new("no choices in the vendor response") if choice.nil?

      message = choice["message"]?
      if (refusal = message.try(&.["refusal"]?).try(&.as_s?).presence)
        raise Error::ImageGen::Moderated.new(refusal)
      end

      finish = choice["finish_reason"]?.try(&.as_s?) || "stop"
      raise Error::ImageGen::Moderated.new("the answer was blocked by the vendor's content filter") if finish == "content_filter"

      text = case content = message.try(&.["content"]?).try(&.raw)
             when String then content
             when Array  then content.compact_map { |part| part["text"]?.try(&.as_s?) }.join
             else             ""
             end

      usage = payload["usage"]?
      Result.new(
        text: text,
        finish: finish,
        input_tokens: usage.try(&.["prompt_tokens"]?).try(&.as_i64?),
        output_tokens: usage.try(&.["completion_tokens"]?).try(&.as_i64?),
        total_tokens: usage.try(&.["total_tokens"]?).try(&.as_i64?),
        vendor_id: payload["id"]?.try(&.as_s?),
      )
    end
  end
end
