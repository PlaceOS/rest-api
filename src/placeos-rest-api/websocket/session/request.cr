require "./base"

struct PlaceOS::Api::WebSocket::Session::Request < PlaceOS::Api::WebSocket::Session::Base
  include JSON::Serializable::Strict

  # Commands available over websocket API
  enum Command
    Exec
    Bind
    Unbind
    Debug
    Ignore
  end

  def initialize(
    @id,
    @system_id,
    @module_name,
    @command,
    @name,
    @index = 1,
    @args = nil
  )
  end

  getter id : Int64

  # Module location metadata
  @[JSON::Field(key: "sys")]
  getter system_id : String

  @[JSON::Field(key: "mod")]
  getter module_name : String

  getter index : Int32 = 1

  # Command
  @[JSON::Field(key: "cmd")]
  getter command : Command

  # Function name
  getter name : String

  # Function arguments
  @[JSON::Field(emit_null: true)]
  getter args : Array(JSON::Any)?
end
