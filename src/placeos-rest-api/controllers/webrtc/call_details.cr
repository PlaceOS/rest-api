require "./clustered_sessions"

module PlaceOS::Api
  class CallDetails
    getter id : String
    getter peers : Hash(String, HTTP::WebSocket)

    getter created_at : Time
    property updated_at : Time

    SESSIONS = ClusteredSessions.new

    def add(user_id : String, websocket : HTTP::WebSocket)
      SESSIONS.add_user(id, user_id)
      peers[user_id] = websocket
      @updated_at = Time.utc
    end

    def remove(user_id : String)
      SESSIONS.remove_user(id, user_id)
      peers.delete user_id
      @updated_at = Time.utc
    end

    def all_peers
      SESSIONS.user_list(id)
    end

    def initialize(@id : String)
      @peers = {} of String => HTTP::WebSocket
      @updated_at = @created_at = Time.utc
    end
  end
end
