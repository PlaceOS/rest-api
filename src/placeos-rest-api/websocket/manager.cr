require "hound-dog"
require "tasker"

require "./session"

module PlaceOS::Api::WebSocket
  # Stores sessions until their websocket closes
  class Manager
    Log = ::Log.for(self)

    private getter session_lock : Mutex = Mutex.new
    private getter sessions : Array(Session) { [] of Session }
    private getter discovery : HoundDog::Discovery

    private getter session_cleanup_period : Time::Span = 1.hours

    @session_cleaner : Tasker::Task?

    def initialize(@discovery : HoundDog::Discovery)
      spawn(name: "cleanup_sessions", same_thread: true) do
        cleanup_sessions
      end
    end

    # Creates the session and handles the cleanup
    #
    def create_session(ws, request_id, user)
      Log.trace { {request_id: request_id, frame: "OPEN"} }
      session = Session.new(
        ws: ws,
        request_id: request_id,
        user: user,
        discovery: discovery,
      )

      session_lock.synchronize { sessions << session }

      ws.on_close do |_|
        Log.trace { {request_id: request_id, frame: "CLOSE"} }
        session.cleanup
        session_lock.synchronize { sessions.delete(session) }
      end
    end

    # Periodically shrink the sessions array
    protected def cleanup_sessions
      @session_cleaner = Tasker.instance.every(session_cleanup_period) do
        Log.trace { "shrinking sessions array" }
        # NOTE: As crystal arrays do not shrink, we create a new one periodically
        session_lock.synchronize { @sessions = sessions.dup }
      end
    end
  end
end
