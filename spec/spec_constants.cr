require "./helper"

module PlaceOS::Api
  class_getter authorization_header : Hash(String, String) do
    _user, header = authentication
    header
  end
end
