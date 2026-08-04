require "json"
require "office365"

module PlaceOS::Api
  # Microsoft Graph is eventually consistent: a directory object that was just
  # created (an application registration or service principal) is not always
  # visible to an immediately following request that references it. Graph
  # signals this as a 404 with the error code `Request_ResourceNotFound`.
  #
  # Retry exactly that case with a backoff; every other error propagates
  # untouched.
  module GraphReplicationRetry
    Log = ::Log.for(self)

    # seconds between attempts, ~23s in total. Replication typically settles
    # within a few seconds.
    BACKOFF = {1, 2, 4, 8, 8}

    def self.run(backoff = BACKOFF, & : -> T) : T forall T
      attempt = 0
      loop do
        begin
          return yield
        rescue error : ::Office365::Exception
          delay = backoff[attempt]?
          raise error unless delay && replication_lag?(error)
          attempt += 1
          Log.warn { "graph resource not replicated yet (attempt #{attempt}), retrying in #{delay}s" }
          sleep delay.seconds
        end
      end
    end

    def self.replication_lag?(error : ::Office365::Exception) : Bool
      return false unless error.http_status.not_found?
      JSON.parse(error.http_body).dig?("error", "code").try(&.as_s?) == "Request_ResourceNotFound"
    rescue JSON::ParseException
      false
    end
  end
end
