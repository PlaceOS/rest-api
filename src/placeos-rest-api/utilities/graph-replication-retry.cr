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

    # seconds between attempts, ~35s in total. Replication typically settles
    # within a few seconds but has been observed (sandbox tenant, 2026-08-04)
    # taking 25s+.
    BACKOFF = {1, 2, 4, 8, 8, 12}

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
      body = JSON.parse(error.http_body)
      case error.http_status
      when .not_found?
        # Request_ResourceNotFound: a just-created object is not yet visible
        # to a request referencing it.
        # Directory_ObjectNotFound ("Unable to read the company information
        # from the directory"): transient directory read failure while the
        # tenant is busy replicating - documented by Microsoft as retryable.
        body.dig?("error", "code").try(&.as_s?).in?("Request_ResourceNotFound", "Directory_ObjectNotFound")
      when .bad_request?
        # NoBackingApplicationObject: a service principal cannot be created
        # because the application object registered moments earlier has not
        # replicated yet.
        # InvalidValue on preAuthorizedApplications.delegatedPermissionIds:
        # the PATCH that added the permission scope moments earlier has not
        # replicated, so the follow-up PATCH fails validation against a stale
        # copy of the application. Deliberately narrow - a generic InvalidValue
        # retry would mask real validation errors.
        details = body.dig?("error", "details").try(&.as_a?) || [] of JSON::Any
        details.any? do |detail|
          code = detail["code"]?.try(&.as_s?)
          target = detail["target"]?.try(&.as_s?)
          code == "NoBackingApplicationObject" ||
            (code == "InvalidValue" && target == "api.preAuthorizedApplications.delegatedPermissionIds")
        end
      when .conflict?
        # Request_MultipleObjectsWithSameKeyValue on a service principal
        # create: the preceding existence check read a stale replica that did
        # not yet list the service principal created moments earlier, so the
        # get-or-create tried to create it twice. Retrying converges - the
        # next read eventually sees the object and the create is skipped.
        body.dig?("error", "code").try(&.as_s?) == "Request_MultipleObjectsWithSameKeyValue"
      else
        false
      end
    rescue JSON::ParseException
      false
    end
  end
end
