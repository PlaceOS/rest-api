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

  private def scoped_id(value : String, authority_id : String? = nil) : String
    authority_id ? {authority_id, value}.to_json : value
  end

  def set_key(session_id : String, authority_id : String? = nil) : String
    "placeos:chat:session:#{Digest::SHA1.hexdigest(scoped_id(session_id, authority_id))}"
  end

  def user_key(user_id : String, authority_id : String? = nil) : String
    "placeos:chat:user:#{Digest::SHA1.hexdigest(scoped_id(user_id, authority_id))}"
  end

  def user_list(session_id : String, authority_id : String? = nil) : Array(String)
    result = with_redis &.smembers(set_key(session_id, authority_id))
    result.compact_map &.as?(String)
  end

  def add_user(session_id : String, user_id : String, authority_id : String? = nil) : Nil
    redis_key = set_key(session_id, authority_id)
    @session_mutex.synchronize { @sessions[scoped_id(session_id, authority_id)] << user_id }
    with_redis do |redis|
      redis.pipelined(redis_key, reconnect: true) do |pipeline|
        pipeline.sadd(redis_key, user_id)
        pipeline.expire(redis_key, TTL_SECONDS)
      end
      redis.set(user_key(user_id, authority_id), session_id, ex: 24.hours.total_seconds.to_i)
    end
  end

  def lookup_session(user_id : String, authority_id : String? = nil)
    with_redis do |redis|
      redis.get(user_key(user_id, authority_id))
    end
  end

  def remove_user(session_id : String, user_id : String, authority_id : String? = nil) : Nil
    local_id = scoped_id(session_id, authority_id)
    @session_mutex.synchronize do
      set = @sessions[local_id]
      set.delete(user_id)
      @sessions.delete(local_id) if set.empty?
    end

    # if the set above is empty then this node will let the session expire
    redis_key = set_key(session_id, authority_id)
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
      sleep sleep_time
      sessions = @session_mutex.synchronize { @sessions.dup }
      WebRTC::Log.info { "[webrtc] maintaining #{sessions.size} sessions" }
      sessions.each_key do |session_id|
        with_redis(&.expire(set_key(session_id), TTL_SECONDS))
      rescue error
        WebRTC::Log.warn(exception: error) { "[webrtc] issue setting session expiry" }
      end
    rescue error
      WebRTC::Log.warn(exception: error) { "[webrtc] unknown issue touching sessions" }
    end
  end
end
