require "json"

# WebSocket API Messages
# :nodoc:
abstract struct PlaceOS::Api::WebSocket::Session::Base
  include JSON::Serializable
end
