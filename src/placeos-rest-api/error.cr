module PlaceOS::Api
  class Error < Exception
    getter message

    def initialize(@message : String = "")
      super(message)
    end

    class Unauthorized < Error
    end

    class Forbidden < Error
    end

    class NotFound < Error
    end

    class Conflict < Error
    end

    class NotAcceptable < Error
    end

    record Field, field : Symbol, message : String

    class RecaptchaFailed < Error
    end

    class GuestAccessDisabled < Error
    end

    # Signage AI image generation. Each subclass maps to its own status code in
    # `Application`, and renders `{"error": ..., "kind": ...}` so a client can
    # branch on the kind without matching on message text.
    class ImageGen < Error
      # the caller has used up a per user or per domain quota
      class Quota < ImageGen
      end

      # the vendor refused the prompt or the source image
      class Moderated < ImageGen
      end

      # no free slot on this replica, the caller should try again shortly
      class Busy < ImageGen
      end

      # the vendor returned something we could not use
      class Vendor < ImageGen
      end

      # the vendor did not answer in time
      class Timeout < ImageGen
      end

      # the caller may not use the referenced upload or item
      class Permission < ImageGen
      end

      # no provider row, no storage, or the feature is switched off
      class NotConfigured < ImageGen
      end

      # kind reported to the client, e.g. "moderation", "quota"
      def kind : String
        case self
        when Quota         then "quota"
        when Moderated     then "moderation"
        when Busy          then "busy"
        when Vendor        then "vendor"
        when Timeout       then "timeout"
        when Permission    then "permission"
        when NotConfigured then "not_configured"
        else                    "error"
        end
      end
    end

    class ModelValidation < Error
      getter failures : Array(NamedTuple(field: Symbol, reason: String))

      def initialize(failures : Enumerable, message : String = "validation failed")
        @failures = failures.map { |fail| {field: fail.field, reason: fail.message} }.to_a
        super(message)
      end
    end
  end
end
