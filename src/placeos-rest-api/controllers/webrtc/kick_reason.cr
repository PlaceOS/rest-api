require "json"

module PlaceOS::Api
  struct KickReason
    include JSON::Serializable

    getter reason : String

    def initialize(@reason)
    end
  end
end
