require "json"

module PlaceOS::Api
  enum SignalType
    Join
    ParticipantList
    Candidate
    Offer
    Answer
    Ping
    Leave

    # this is sent to the client when someone is to be moved into a new space
    # the session id may or may not change - if session_id is different
    # then the user will be cleaned up as if disconnect was called, allowing them
    # to call join again, similar semantics to leave
    Transfer
  end

  struct SessionSignal
    include JSON::Serializable

    # message id, generated by the sender
    getter id : String

    # the unique id of the chat to join
    property session_id : String

    # the type of message
    property type : SignalType

    # the chat user identifier, globally unique
    getter user_id : String

    @[JSON::Field(ignore: true)]
    property place_user_id : String? = nil

    @[JSON::Field(ignore: true)]
    property place_auth_id : String? = nil

    # the id of the user we want to communicate with
    property to_user : String?

    # the payload, if any
    @[JSON::Field(converter: String::RawConverter)]
    property value : String?

    def initialize(@id, @session_id, @type, @user_id, @to_user, @value)
    end
  end
end
