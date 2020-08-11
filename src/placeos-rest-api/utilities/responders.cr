require "http"

module PlaceOS::Api
  module Utils::Responders
    # Shortcut to save a record and render a response
    def save_and_respond(resource)
      result, status = save_and_status(resource)
      render json: result, status: status
    end

    # Shortcut to save a record and give the correct
    def save_and_status(resource)
      creation = resource.new_record?
      if resource.save
        {resource, creation ? HTTP::Status::CREATED : HTTP::Status::OK}
      else
        {resource.errors.map(&.to_s), HTTP::Status::UNPROCESSABLE_ENTITY}
      end
    end

    # Merge fields into object
    def with_fields(model, fields) : Hash
      attrs = Hash(String, JSON::Any).from_json(model.to_json)
      attrs.merge(fields)
    end

    # Restrict model attributes
    def restrict_attributes(
      model,
      only : Array(String)? = nil,   # Attributes to keep
      except : Array(String)? = nil, # Attributes to exclude
      fields : Hash? = nil           # Additional fields
    ) : Hash
      # Necessary for fields with converters defined
      attrs = Hash(String, JSON::Any).from_json(model.to_json)
      attrs.select!(only) if only
      attrs.reject!(except) if except

      fields && !fields.empty? ? attrs.merge(fields) : attrs
    end

    private alias DriverError = Driver::Proxy::RemoteDriver::ErrorCode

    # RemoteDriver Execute error responder
    #
    # With respond = `true`, method acts as a logging function
    def handle_execute_error(error : Driver::Proxy::RemoteDriver::Error, respond : Bool = true)
      message = error.error_code.to_s.gsub('_', ' ')
      Log.context.set(
        error: message,
        sys_id: error.system_id,
        module_name: error.module_name,
        index: error.index,
        remote_backtrace: error.remote_backtrace,
      )

      status = case error.error_code
               when DriverError::ModuleNotFound, DriverError::SystemNotFound
                 Log.info { error.message }
                 HTTP::Status::NOT_FOUND
               when DriverError::ParseError, DriverError::BadRequest, DriverError::UnknownCommand
                 Log.error { error.message }
                 HTTP::Status::BAD_REQUEST
               when DriverError::RequestFailed, DriverError::UnexpectedFailure
                 Log.info { error.message }
                 HTTP::Status::INTERNAL_SERVER_ERROR
               when DriverError::AccessDenied
                 Log.info { error.message }
                 HTTP::Status::UNAUTHORIZED
               else
                 raise "unexpected error code #{error.error_code}"
               end

      render(status: status, text: message) if respond
    end
  end
end
