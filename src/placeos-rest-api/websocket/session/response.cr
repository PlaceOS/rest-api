require "placeos-driver/proxy/remote_driver"

require "./base"

struct PlaceOS::Api::WebSocket::Session::Response < PlaceOS::Api::WebSocket::Session::Base
  # WebSocket API Response
  # Driver response error codes
  alias ErrorCode = Driver::Proxy::RemoteDriver::ErrorCode

  # Response type
  enum Type
    Success
    Notify
    Error
    Debug
  end

  getter id : Int64
  getter type : Type

  @[JSON::Field(key: "msg")]
  getter message : String?

  @[JSON::Field(converter: String::RawConverter)]
  getter value : String?

  @[JSON::Field(converter: Enum::ValueConverter(PlaceOS::Api::WebSocket::Session::Response::ErrorCode))]
  getter error_code : ErrorCode?

  @[JSON::Field(key: "meta")]
  getter metadata : Metadata?

  @[JSON::Field(key: "mod")]
  getter module_id : String?

  getter level : ::Log::Severity?

  alias Metadata = NamedTuple(
    sys: String,
    mod: String,
    index: Int32,
    name: String,
  )

  def initialize(
    @id : Int64,
    @type : Type,
    @error_code : ErrorCode? = nil,
    message : String? = nil,
    value : String? = nil,
    @module_id : String? = nil,
    @level : ::Log::Severity? = nil,
    @metadata : Metadata? = nil
  )
    # Remove invalid UTF-8 data from the payload
    @value = value.is_a?(String) ? value.scrub : nil
    # Remove invalid UTF-8 data from the error message
    @message = message.is_a?(String) ? message.scrub : nil
  end
end
