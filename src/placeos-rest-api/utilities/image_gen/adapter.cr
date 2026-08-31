require "placeos-models/signage_ai_provider"

module PlaceOS::Api::ImageGen
  # A vendor. Adapters take an `AdapterRequest` and return images, or raise:
  #
  # - `Error::ImageGen::Moderated` when the vendor refused the prompt or source
  # - `Error::ImageGen::Vendor`    for anything else the vendor said
  # - `IO::TimeoutError`           when it did not answer, mapped to 504 upstream
  #
  # They never see a job row, a model or the request.
  abstract class Adapter
    getter row : ::PlaceOS::Model::SignageAIProvider

    def initialize(@row : ::PlaceOS::Model::SignageAIProvider)
    end

    abstract def capabilities : ProviderCapabilities
    abstract def generate(request : AdapterRequest) : Array(AdapterImage)
    abstract def edit(request : AdapterRequest) : Array(AdapterImage)

    # how many images one call can return. OpenAI answers with every candidate
    # from a single call, Google returns one image per call, so the runner
    # divides the work accordingly and reserves a slot for each call.
    abstract def images_per_call : Int32

    # number of vendor calls needed for this many candidates
    def calls_for(candidates : Int32) : Int32
      per_call = images_per_call
      return candidates if per_call <= 1
      (candidates + per_call - 1) // per_call
    end

    def call(request : AdapterRequest) : Array(AdapterImage)
      case request.kind
      in Kind::Generate then generate(request)
      in Kind::Edit     then edit(request)
      end
    end

    def self.for(row : ::PlaceOS::Model::SignageAIProvider) : Adapter
      case row.provider
      in ::PlaceOS::Model::SignageAIProvider::Provider::OPENAI,
         ::PlaceOS::Model::SignageAIProvider::Provider::AZURE_OPENAI
        Adapters::OpenAIImages.new(row)
      in ::PlaceOS::Model::SignageAIProvider::Provider::GOOGLE_VERTEX
        Adapters::GeminiVertex.new(row)
      end
    end

    # models a row is allowed to use, its own list or the adapter's defaults
    protected def allowed(defaults : Array(ModelCapabilities)) : Array(ModelCapabilities)
      allow = row.allowed_models
      return defaults if allow.empty?
      defaults.select { |model| allow.includes?(model.id) }
    end

    protected def credentials : Hash(String, JSON::Any)
      row.credentials_json
    rescue ex : ::PlaceOS::Model::Error
      raise Error::ImageGen::NotConfigured.new(ex.message || "provider credentials could not be read")
    end

    protected def credential(key : String) : String
      value = credentials[key]?.try(&.as_s?)
      raise Error::ImageGen::NotConfigured.new("provider #{row.name} is missing #{key}") if value.nil? || value.empty?
      value
    end

    # trimmed so a vendor body never lands whole in the logs or an API response
    protected def vendor_message(body : String, limit : Int32 = 300) : String
      cleaned = body.gsub(/\s+/, " ").strip
      cleaned.size > limit ? "#{cleaned[0, limit]}..." : cleaned
    end
  end
end
