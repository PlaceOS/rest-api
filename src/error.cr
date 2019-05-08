module Engine::API
  class Error < Exception
    getter :message

    def initialize(@message : String? = "")
      super(message)
    end

    class ParameterMissing < Error
    end
  end
end
