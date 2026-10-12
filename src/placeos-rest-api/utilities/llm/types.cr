require "json"

module PlaceOS::Api::Llm
  # One piece of the user turn. Parts are sent in the order given.
  record TextPart, text : String
  record ImagePart, bytes : Bytes, mime : String, detail : String = "high"
  alias Part = TextPart | ImagePart

  # What an adapter is asked to do. Adapters never see a job row or a request.
  #
  # With a `schema` the vendor is asked for JSON matching it; without one the
  # answer is free text.
  record Request,
    system : String,
    parts : Array(Part),
    model : String,
    max_output_tokens : Int32,
    schema : JSON::Any? = nil,
    schema_name : String = "map_edit",
    reasoning_effort : String? = "low" do
    # every text part joined, in order
    def text : String
      parts.compact_map { |part| part.as?(TextPart).try(&.text) }.join("\n\n")
    end

    def images : Array(ImagePart)
      parts.compact_map(&.as?(ImagePart))
    end
  end

  # One answer back from a vendor. `finish` is the vendor's stop reason,
  # normalised to stop, length or other.
  record Result,
    text : String,
    finish : String,
    input_tokens : Int64? = nil,
    output_tokens : Int64? = nil,
    total_tokens : Int64? = nil,
    vendor_id : String? = nil do
    def usage : Hash(String, JSON::Any)
      {
        "input_tokens"  => JSON::Any.new(input_tokens),
        "output_tokens" => JSON::Any.new(output_tokens),
        "total_tokens"  => JSON::Any.new(total_tokens),
        "finish"        => JSON::Any.new(finish),
      }
    end
  end

  struct ProviderCapabilities
    include JSON::Serializable

    getter id : String
    getter name : String
    getter provider : String
    getter text_model : String

    def initialize(@id, @name, @provider, @text_model)
    end
  end
end
