require "http"

module ACAEngine::Api
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
    def driver_execute_error_response(error : Driver::Proxy::RemoteDriver::Error)
      message = error.error_code.to_s.gsub('_', ' ')
      meta = {
        message:     error.message || "",
        error:       message,
        sys_id:      error.system_id,
        module_name: error.module_name,
        index:       error.index,
      }
      case error.error_code
      when Driver::Proxy::RemoteDriver::ErrorCode::ModuleNotFound,
           Driver::Proxy::RemoteDriver::ErrorCode::SystemNotFound
        logger.tag_info(**meta)
        render status: :not_found, text: message
      when Driver::Proxy::RemoteDriver::ErrorCode::ParseError,
           Driver::Proxy::RemoteDriver::ErrorCode::BadRequest,
           Driver::Proxy::RemoteDriver::ErrorCode::UnknownCommand
        logger.tag_error(**meta.merge({remote_backtrace: error.remote_backtrace}))
        render status: :bad_request, text: message
      when Driver::Proxy::RemoteDriver::ErrorCode::RequestFailed,
           Driver::Proxy::RemoteDriver::ErrorCode::UnexpectedFailure
        logger.tag_info(**meta.merge({remote_backtrace: error.remote_backtrace}))
        render status: :internal_server_error, text: message
      when Driver::Proxy::RemoteDriver::ErrorCode::AccessDenied
        logger.tag_info(**meta)
        head :unauthorized
      end
    end
  end
end
