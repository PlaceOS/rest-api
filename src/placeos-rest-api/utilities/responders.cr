require "http"
require "placeos-models"

module PlaceOS::Api
  module Utils::Responders
    # Renders API error messages in a consistent format
    #
    def render_error(status : HTTP::Status, message : String?, **additional)
      message = "API error" if message.nil?
      render status: status, json: additional.merge({message: message})
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
               in DriverError::ModuleNotFound, DriverError::SystemNotFound
                 Log.info { error.message }
                 HTTP::Status::NOT_FOUND
               in DriverError::ParseError, DriverError::BadRequest, DriverError::UnknownCommand
                 Log.error { error.message }
                 HTTP::Status::BAD_REQUEST
               in DriverError::RequestFailed, DriverError::UnexpectedFailure
                 Log.info { error.message }
                 error.response_code
               in DriverError::AccessDenied
                 Log.info { error.message }
                 HTTP::Status::UNAUTHORIZED
               end

      render(status: status, json: {
        error:       message,
        sys_id:      error.system_id,
        module_name: error.module_name,
        index:       error.index,
        message:     error.message,
        backtrace:   error.remote_backtrace,
      }) if respond
    end
  end
end
