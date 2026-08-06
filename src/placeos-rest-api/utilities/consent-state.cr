require "uuid"

module PlaceOS::Api
  # The `state` parameter for an Azure admin-consent round trip.
  #
  # Microsoft redirects the browser to `/admin_consent/callback`, so that route
  # cannot carry a session and cannot be authenticated. Everything the callback
  # goes on to do — registering applications, writing an oauth strat, replacing
  # the staff API tenant's calendar credentials, and overwriting the authority's
  # `login_url` — is therefore driven entirely by its query parameters.
  #
  # Passing the authority id there directly, as this flow used to, means anyone
  # who can reach the deployment can point any authority at an identity provider
  # they control, because `state` was echoed rather than verified.
  #
  # So `state` is an opaque single-use token instead. It exists only because an
  # authenticated administrator asked to start a flow for a specific authority,
  # it names that authority server side rather than carrying it in the URL, it
  # expires, and redeeming it destroys it. A captured callback URL is worthless
  # once used, and a guessed one is worth nothing at all.
  module ConsentState
    # Long enough for an admin to read Microsoft's consent screen and decide.
    TTL_SECONDS = 900

    # Records a pending flow for `authority_id` and returns the token to send
    # to Microsoft as `state`.
    def self.issue(authority_id : String) : String
      token = UUID.random.to_s
      ::PlaceOS::Driver::RedisStorage.with_redis(&.set(
        redis_key(token), authority_id, ex: TTL_SECONDS
      ))
      token
    end

    # Redeems `token`, returning the authority it was issued for, or `nil` if it
    # is unknown, expired, or already used.
    def self.consume(token : String) : String?
      key = redis_key(token)
      ::PlaceOS::Driver::RedisStorage.with_redis do |redis|
        authority_id = redis.get(key)
        next nil unless authority_id

        # `del` reports how many keys it removed. Anything other than one means
        # a concurrent request redeemed this token first, and only that request
        # may proceed — otherwise a replayed callback would still be honoured
        # in the window before the delete lands.
        next nil unless redis.del(key) == 1

        authority_id
      end
    end

    def self.redis_key(token : String) : String
      "placeos:admin_consent:state:#{token}"
    end
  end
end
