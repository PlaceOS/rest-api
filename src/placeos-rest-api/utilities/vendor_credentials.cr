require "placeos-models/signage_ai_provider"

module PlaceOS::Api
  # Reads a provider row's encrypted credentials for a vendor adapter.
  #
  # The including class exposes the row as `row`. An unreadable or
  # incomplete credential raises `Error::ImageGen::NotConfigured`.
  module Utils::VendorCredentials
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
