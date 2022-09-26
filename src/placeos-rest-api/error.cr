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

    class ModelValidation < Error
      getter failures : Array(NamedTuple(field: Symbol, reason: String))

      def initialize(failures : Enumerable(ActiveModel::Error), message : String = "validation failed")
        @failures = failures.map { |fail| {field: fail.field, reason: fail.message} }.to_a
        super(message)
      end
    end

    # TODO:: remove below:
    class NoBody < Error
    end

    class InvalidParams < Error
      getter params

      def initialize(@params : Params, message = "")
        super(message)
      end
    end
  end
end
