require "placeos-models/signage_ai_provider"

require "../vendor_credentials"

module PlaceOS::Api::Llm
  # A vendor's text/vision model. Adapters take a `Request` and return a
  # `Result`, or raise:
  #
  # - `Error::ImageGen::Moderated` when the vendor refused the prompt
  # - `Error::ImageGen::Busy`      when the vendor is rate limiting
  # - `Error::ImageGen::Timeout`   when it did not answer in time
  # - `Error::ImageGen::Vendor`    for anything else the vendor said
  #
  # They never see a job row or a request.
  abstract class Adapter
    include Utils::VendorCredentials

    getter row : ::PlaceOS::Model::SignageAIProvider

    def initialize(@row : ::PlaceOS::Model::SignageAIProvider)
    end

    abstract def complete(request : Request) : Result

    # the model used when the row names no text_model
    abstract def default_text_model : String

    def text_model : String
      row.text_model.presence || default_text_model
    end

    # the reasoning effort asked of the vendor's models
    def default_effort : String?
      "low"
    end

    def capabilities : ProviderCapabilities
      ProviderCapabilities.new(
        id: row.id.to_s,
        name: row.name,
        provider: row.provider.to_s,
        text_model: text_model,
        text_models: text_models,
      )
    end

    # whether a row's vendor has a text adapter here
    def self.supports?(row : ::PlaceOS::Model::SignageAIProvider) : Bool
      row.provider.openai_compatible? || row.provider.anthropic?
    end

    # the text models a row's vendor is known to serve, the row's own first
    def text_models : Array(String)
      ([text_model] + known_text_models).uniq
    end

    abstract def known_text_models : Array(String)

    def self.for(row : ::PlaceOS::Model::SignageAIProvider) : Adapter
      case row.provider
      in ::PlaceOS::Model::SignageAIProvider::Provider::OPENAI,
         ::PlaceOS::Model::SignageAIProvider::Provider::AZURE_OPENAI
        Adapters::OpenAIChat.new(row)
      in ::PlaceOS::Model::SignageAIProvider::Provider::GOOGLE_VERTEX
        raise Error::ImageGen::NotConfigured.new("provider #{row.name} is a Google Vertex row, which cannot edit maps yet")
      in ::PlaceOS::Model::SignageAIProvider::Provider::ANTHROPIC
        Adapters::AnthropicMessages.new(row)
      end
    end
  end
end
