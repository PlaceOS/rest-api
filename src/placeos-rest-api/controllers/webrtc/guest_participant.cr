require "json"

module PlaceOS::Api
  class GuestParticipant
    include JSON::Serializable

    property captcha : String
    property name : String
    property email : String?
    property phone : String?

    # the type of guest (additional information)
    property type : String?

    # the placeos user id we would like to notify if we have the user details
    property chat_to_user_id : String?

    # the users chat id. This purely generated on the frontend
    # not a placeos user_id, we use it to track browser instances
    property user_id : String

    # the chat session id the user is planning to use, the initial chat room
    property session_id : String
  end
end
