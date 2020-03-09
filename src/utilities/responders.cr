require "http"

module PlaceOS::Api
  module Utils::Responders
    # Shortcut to save a record and render a response
    def save_and_respond(resource)
      creation = resource.new_record?
      if resource.save
        render json: resource, status: creation ? HTTP::Status::CREATED : HTTP::Status::OK
      else
        render json: resource.errors.map(&.to_s), status: :unprocessable_entity
      end
    end

    def with_fields(model, fields)
      attr = JSON.parse(model.to_json).as_h
      attr.merge(fields)
    end

    # Restrict model attributes
    # FIXME: _incredibly_ inefficient, optimise
    def restrict_attributes(
      model,
      only : Array(String)? = nil,   # Attributes to keep
      except : Array(String)? = nil, # Attributes to exclude
      fields : Hash? = nil           # Additional fields
    ) : Hash
      # Necessary for fields with converters defined
      attrs = JSON.parse(model.to_json).as_h
      attrs.select!(only) if only
      attrs.reject!(except) if except
      attrs.merge(fields) if fields

      fields ? attrs.merge(fields) : attrs
    end

    # RemoteDriver Execute error responder
    #
    # With respond = `true`, method acts as a logging function
    def handle_execute_error(error : Driver::Proxy::RemoteDriver::Error, respond : Bool = true)
      status, severity = case error.error_code
                         when Driver::Proxy::RemoteDriver::ErrorCode::ModuleNotFound,
                              Driver::Proxy::RemoteDriver::ErrorCode::SystemNotFound
                           {HTTP::Status::NOT_FOUND, Logger::Severity::INFO}
                         when Driver::Proxy::RemoteDriver::ErrorCode::ParseError,
                              Driver::Proxy::RemoteDriver::ErrorCode::BadRequest,
                              Driver::Proxy::RemoteDriver::ErrorCode::UnknownCommand
                           {HTTP::Status::BAD_REQUEST, Logger::Severity::ERROR}
                         when Driver::Proxy::RemoteDriver::ErrorCode::RequestFailed,
                              Driver::Proxy::RemoteDriver::ErrorCode::UnexpectedFailure
                           {HTTP::Status::INTERNAL_SERVER_ERROR, Logger::Severity::INFO}
                         when Driver::Proxy::RemoteDriver::ErrorCode::AccessDenied
                           {HTTP::Status::UNAUTHORIZED, Logger::Severity::INFO}
                         end.not_nil! # TODO: remove once merged https://github.com/crystal-lang/crystal/pull/8424
      message = error.error_code.to_s.gsub('_', ' ')
      logger.tag(
        message: error.message || "",
        severity: severity,
        error: message,
        sys_id: error.system_id,
        module_name: error.module_name,
        index: error.index,
        remote_backtrace: error.remote_backtrace,
      )
      render(status: status, text: message) if respond
    end
  end
end
