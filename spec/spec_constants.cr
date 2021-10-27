require "./helper"

module PlaceOS::Api
  class_getter authorization_header : Hash(String, String) do
    # ameba:disable Lint/UselessAssign
    _, header = authentication
  end
end
