require "http/client"
require "json"

module PlaceOS::Api
  # Endpoint, authentication and error mapping shared by the OpenAI and Azure
  # OpenAI adapters, for images and for map edits.
  #
  # The including class exposes the provider row as `row` and includes
  # `Utils::VendorCredentials`.
  module Utils::OpenAIVendor
    OPENAI_BASE = "https://api.openai.com/v1"

    # error codes OpenAI and Azure use when a safety system blocked the request
    MODERATION_CODES = {"content_filter", "moderation_blocked", "content_policy_violation"}

    protected def azure? : Bool
      row.provider.azure_openai?
    end

    # the row's endpoint without a trailing slash; Azure rows must set one
    protected def base : String
      if (endpoint = row.endpoint.presence)
        endpoint.rstrip('/')
      elsif azure?
        raise Error::ImageGen::NotConfigured.new("Azure OpenAI provider #{row.name} needs an endpoint")
      else
        OPENAI_BASE
      end
    end

    protected def openai_headers(content_type : String) : HTTP::Headers
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

    protected def raise_for_status(response : HTTP::Client::Response) : Nil
      return if response.success?

      code = nil
      message = nil
      begin
        error = JSON.parse(response.body)["error"]?
        code = error.try(&.["code"]?).try(&.as_s?)
        message = error.try(&.["message"]?).try(&.as_s?)
      rescue JSON::ParseException
      end

      if code && MODERATION_CODES.includes?(code)
        raise Error::ImageGen::Moderated.new(message || "the request was blocked by the vendor's safety system")
      end

      if response.status_code == 429
        raise Error::ImageGen::Busy.new(message || "the vendor is rate limiting this account")
      end

      raise Error::ImageGen::Vendor.new(message || vendor_message(response.body))
    end
  end
end
