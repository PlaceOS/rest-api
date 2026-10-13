require "base64"
require "json"

module PlaceOS::Api::Llm::Adapters
  # The Anthropic Messages API. The answer is asked for as JSON matching the
  # op schema through `output_config.format` and read back from the text block.
  #
  # Models whose safety classifiers may decline a request are sent
  # `fallbacks: "default"`, and the API reruns a declined request on its
  # recommended fallback model inside the same call; the response then names
  # the model that answered.
  class AnthropicMessages < Adapter
    DEFAULT_BASE = "https://api.anthropic.com"
    API_VERSION  = "2023-06-01"

    FALLBACK_BETA = "server-side-fallback-2026-07-01"

    # model id prefixes that take the fallbacks parameter
    FALLBACK_MODELS = %w(claude-fable-5 claude-mythos-5 claude-opus-5)

    def default_text_model : String
      MAP_AI_DEFAULT_ANTHROPIC_MODEL
    end

    def known_text_models : Array(String)
      MAP_AI_ANTHROPIC_MODELS
    end

    def default_effort : String?
      MAP_AI_ANTHROPIC_EFFORT
    end

    def complete(request : Request) : Result
      fallbacks = fallbacks?(request.model)
      effort = request.reasoning_effort
      response = post(body_for(request, fallbacks, effort), fallbacks)

      # a model that takes neither parameter rejects the whole request naming
      # it; sent again without
      2.times do
        break unless response.status_code == 400
        if fallbacks && response.body.includes?("fallbacks")
          fallbacks = false
        elsif effort && response.body.includes?("effort")
          effort = nil
        else
          break
        end
        response = post(body_for(request, fallbacks, effort), fallbacks)
      end

      raise_for_status(response)
      parse(response.body)
    rescue IO::TimeoutError
      raise Error::ImageGen::Timeout.new("the model did not answer within #{MAP_AI_READ_TIMEOUT.total_seconds.to_i} seconds")
    end

    private def fallbacks?(model : String) : Bool
      FALLBACK_MODELS.any? { |prefix| model.starts_with?(prefix) }
    end

    private def body_for(request : Request, fallbacks : Bool, effort : String?) : String
      JSON.build do |json|
        json.object do
          json.field "model", request.model
          json.field "max_tokens", request.max_output_tokens
          json.field "system", request.system
          json.field "messages" do
            json.array do
              json.object do
                json.field "role", "user"
                json.field "content" do
                  json.array do
                    request.parts.each { |part| part_json(json, part) }
                  end
                end
              end
            end
          end
          if request.schema || effort
            json.field "output_config" do
              json.object do
                if (schema = request.schema)
                  json.field "format" do
                    json.object do
                      json.field "type", "json_schema"
                      json.field "schema" { Schema.anthropic(schema).to_json(json) }
                    end
                  end
                end
                json.field "effort", effort if effort
              end
            end
          end
          json.field "fallbacks", "default" if fallbacks
        end
      end
    end

    private def part_json(json : JSON::Builder, part : Part) : Nil
      case part
      in TextPart
        json.object do
          json.field "type", "text"
          json.field "text", part.text
        end
      in ImagePart
        json.object do
          json.field "type", "image"
          json.field "source" do
            json.object do
              json.field "type", "base64"
              json.field "media_type", part.mime
              json.field "data", Base64.strict_encode(part.bytes)
            end
          end
        end
      end
    end

    private def url : URI
      base = row.endpoint.presence.try(&.rstrip('/')) || DEFAULT_BASE
      URI.parse("#{base}/v1/messages")
    end

    private def headers(fallbacks : Bool) : HTTP::Headers
      headers = HTTP::Headers{
        "Content-Type"      => "application/json",
        "x-api-key"         => credential("api_key"),
        "anthropic-version" => API_VERSION,
      }
      if workspace_id = credentials["workspace_id"]?.try(&.as_s?).try(&.strip).presence
        headers["anthropic-workspace-id"] = workspace_id
      end
      headers["anthropic-beta"] = FALLBACK_BETA if fallbacks
      headers
    end

    private def post(body : String, fallbacks : Bool) : HTTP::Client::Response
      uri = url
      ImageGen::Http.client(uri, MAP_AI_READ_TIMEOUT) do |client|
        client.post(uri.request_target, headers: headers(fallbacks), body: body)
      end
    end

    private def raise_for_status(response : HTTP::Client::Response) : Nil
      return if response.success?

      type = nil
      message = nil
      begin
        error = JSON.parse(response.body)["error"]?
        type = error.try(&.["type"]?).try(&.as_s?)
        message = error.try(&.["message"]?).try(&.as_s?)
      rescue JSON::ParseException
      end

      if response.status_code == 429 || type == "rate_limit_error" || type == "overloaded_error"
        raise Error::ImageGen::Busy.new(message || "the vendor is rate limiting this account")
      end

      raise Error::ImageGen::Vendor.new(message || vendor_message(response.body))
    end

    private def parse(body : String) : Result
      payload = begin
        JSON.parse(body)
      rescue JSON::ParseException
        raise Error::ImageGen::Vendor.new("the vendor response was not JSON")
      end

      stop = payload["stop_reason"]?.try(&.as_s?) || "end_turn"
      if stop == "refusal"
        details = payload["stop_details"]?
        explanation = details.try(&.["explanation"]?).try(&.as_s?).presence
        category = details.try(&.["category"]?).try(&.as_s?).presence
        raise Error::ImageGen::Moderated.new(
          explanation || "the request was declined by the vendor's safety system#{category ? " (#{category})" : ""}"
        )
      end

      blocks = payload["content"]?.try(&.as_a?) || [] of JSON::Any
      text = blocks.compact_map do |block|
        block["type"]?.try(&.as_s?) == "text" ? block["text"]?.try(&.as_s?) : nil
      end.join

      finish = case stop
               when "end_turn", "stop_sequence" then "stop"
               when "max_tokens"                then "length"
               else                                  "other"
               end

      usage = payload["usage"]?
      input = usage.try(&.["input_tokens"]?).try(&.as_i64?)
      output = usage.try(&.["output_tokens"]?).try(&.as_i64?)
      Result.new(
        text: text,
        finish: finish,
        input_tokens: input,
        output_tokens: output,
        total_tokens: input && output ? input + output : nil,
        vendor_id: payload["id"]?.try(&.as_s?),
        model: payload["model"]?.try(&.as_s?),
      )
    end
  end
end
