require "../helper"

module PlaceOS::Api
  describe ClusteredSessions, focus: true do
    sessions = ClusteredSessions.new
    session_id = UUID.random.to_s
    user_id = UUID.random.to_s

    before_each do
      sessions = ClusteredSessions.new
      session_id = UUID.random.to_s
      user_id = UUID.random.to_s
    end

    it "adds a user to a session" do
      sessions.local_sessions.should eq [] of String
      sessions.add_user(session_id, user_id)
      sessions.local_sessions.should eq [session_id]
      sessions.user_list(session_id).should eq [user_id]
    end

    it "removes a user from a session" do
      sessions.add_user(session_id, user_id)
      sessions.user_list(session_id).should eq [user_id]
      sessions.remove_user(session_id, user_id)
      sessions.user_list(session_id).should eq [] of String
      sessions.local_sessions.should eq [] of String
    end

    it "list users even if the session doesn't exist" do
      sessions.user_list(session_id).should eq [] of String
    end
  end
end
