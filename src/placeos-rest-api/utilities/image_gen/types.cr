require "json"

module PlaceOS::Api::ImageGen
  enum Kind
    Generate
    Edit
  end

  # An image handed to a vendor as context. `role` is only used to build the
  # prompt text, the vendors take an ordered list.
  record Reference, bytes : Bytes, mime : String, role : String = "reference"

  # What an adapter is asked to do. Adapters never see a model, a job row or a
  # request: everything they need is here.
  record AdapterRequest,
    kind : Kind,
    prompt : String,
    aspect : String,
    quality : String,
    candidates : Int32,
    model : String,
    references : Array(Reference) = [] of Reference,
    source : Reference? = nil,
    options : Hash(String, JSON::Any) = {} of String => JSON::Any,
    # overrides the size the aspect would give. Only the credentials check uses
    # this, to ask for the cheapest thing a vendor will draw.
    size_override : String? = nil do
    def width : Int32
      ImageGen.size_for(aspect)[0]
    end

    def height : Int32
      ImageGen.size_for(aspect)[1]
    end

    def size : String
      size_override || "#{width}x#{height}"
    end
  end

  # One image back from a vendor.
  record AdapterImage,
    bytes : Bytes,
    mime : String = "image/jpeg",
    width : Int32? = nil,
    height : Int32? = nil,
    vendor_id : String? = nil,
    cost_units : Float64? = nil

  struct ModelCapabilities
    include JSON::Serializable

    getter id : String
    getter name : String
    getter? generate : Bool
    getter? edit : Bool
    getter? enhance : Bool
    getter max_references : Int32
    getter max_candidates : Int32
    getter qualities : Array(String)
    getter aspect_ratios : Array(String)

    def initialize(@id, @name, @generate = true, @edit = true, @enhance = true,
                   @max_references = 8, @max_candidates = MAX_CANDIDATES,
                   @qualities = QUALITIES, @aspect_ratios = ASPECTS)
    end
  end

  struct ProviderCapabilities
    include JSON::Serializable

    getter id : String
    getter name : String
    getter provider : String
    getter region : String?
    getter default_model : String?
    getter models : Array(ModelCapabilities)

    def initialize(@id, @name, @provider, @models, @default_model = nil, @region = nil)
    end
  end
end
