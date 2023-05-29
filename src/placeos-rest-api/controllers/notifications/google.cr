module PlaceOS::Api
  struct GoogleNotification
    include JSON::Serializable
    include YAML::Serializable

    enum ResourceState
      SYNC
      EXISTS
      NOT_EXISTS

      def to_payload
        case self
        when .exists?     then "updated"
        when .not_exists? then "deleted"
        else                   "renew"
        end
      end
    end

    @[JSON::Field(key: "X-Goog-Channel-ID")]
    getter channel_id : String

    @[JSON::Field(key: "X-Goog-Message-Number")]
    getter message_num : String

    @[JSON::Field(key: "X-Goog-Resource-ID")]
    getter resource_id : String

    @[JSON::Field(key: "X-Goog-Resource-State")]
    getter resource_state : ResourceState

    @[JSON::Field(key: "X-Goog-Resource-URI")]
    getter resource_uri : String

    @[JSON::Field(key: "X-Goog-Channel-Expiration", converter: PlaceOS::Api::ExpiryConverter)]
    getter channel_expiry : Time?

    @[JSON::Field(key: "X-Goog-Channel-Token")]
    getter channel_token : String?

    def to_payload
      [{
        "event_type":      resource_state.to_payload,
        "resource_uri":    resource_uri,
        "subscription_id": channel_id,
        "client_secret":   channel_token,
        "expiration_time": channel_expiry.try &.to_unix || 0_i64,
      }].to_json
    end
  end

  module ExpiryConverter
    def self.from_json(pull : JSON::PullParser)
      string = pull.read_string
      Time::Format::HTTP_DATE.parse(string)
    end

    def self.to_json(value : Time, json : JSON::Builder) : Nil
      Time::Format::HTTP_DATE.format(value).to_json(json)
    end
  end
end
