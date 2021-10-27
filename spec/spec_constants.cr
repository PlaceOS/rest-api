require "./helper"

module PlaceOS::Api
  class_getter authorization_header : Hash(String, String) do
    _, header = authentication
  end
end
