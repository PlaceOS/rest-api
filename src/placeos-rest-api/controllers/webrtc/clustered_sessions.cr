require "set"
require "digest"
require "placeos-driver/proxy/remote_driver"

# stores the session participant IDs in a set in redis
class PlaceOS::Api::ClusteredSessions
  def initialize
    sleep_time = 60 + rand(50)
    spawn { touch_sessions(sleep_time.seconds) }
  end

  # we track local sessions and keep those keys alive in redis
  TTL_SECONDS = 6.minutes.total_seconds.to_i
  @session_mutex = Mutex.new
  @sessions = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }

  protected def with_redis(&)
    ::PlaceOS::Driver::RedisStorage.with_redis do |redis|
      yield redis
    end
  end

  def local_sessions
    @session_mutex.synchronize { @sessions.keys }
  end

  def set_key(session_id : String) : String
    "placeos:chat:session:#{Digest::SHA1.hexdigest(session_id)}"
  end

  def user_key(user_id : String) : String
    "placeos:chat:user:#{Digest::SHA1.hexdigest(user_id)}"
  end

  def user_list(session_id : String) : Array(String)
    result = with_redis &.smembers(set_key(session_id))
    result.compact_map &.as?(String)
  end

  def add_user(session_id : String, user_id : String) : Nil
    redis_key = set_key(session_id)
    @session_mutex.synchronize { @sessions[session_id] << user_id }
    with_redis do |redis|
      redis.pipelined(redis_key, reconnect: true) do |pipeline|
        pipeline.sadd(redis_key, user_id)
        pipeline.expire(redis_key, TTL_SECONDS)
      end
      redis.set(user_key(user_id), session_id, ex: 24.hours.total_seconds.to_i)
    end
  end

  def lookup_session(user_id : String)
    with_redis do |redis|
      redis.get(user_key(user_id))
    end
  end

  def remove_user(session_id : String, user_id : String) : Nil
    @session_mutex.synchronize do
      set = @sessions[session_id]
      set.delete(user_id)
      @sessions.delete(session_id) if set.empty?
    end

    # if the set above is empty then this node will let the session expire
    redis_key = set_key(session_id)
    with_redis do |redis|
      redis.pipelined(redis_key, reconnect: true) do |pipeline|
        pipeline.srem(redis_key, user_id)
        pipeline.expire(redis_key, TTL_SECONDS)
      end
      # NOTE:: don't remove the user lookup to avoid race conditions
    end
  end

  def touch_sessions(sleep_time : Time::Span)
    loop do
      begin
        sleep sleep_time
        sessions = @session_mutex.synchronize { @sessions.dup }
        WebRTC::Log.info { "[webrtc] maintaining #{sessions.size} sessions" }
        sessions.each_key do |session_id|
          begin
            with_redis(&.expire(set_key(session_id), TTL_SECONDS))
          rescue error
            WebRTC::Log.warn(exception: error) { "[webrtc] issue setting session expiry" }
          end
        end
      rescue error
        WebRTC::Log.warn(exception: error) { "[webrtc] unknown issue touching sessions" }
      end
    end
  end
end
