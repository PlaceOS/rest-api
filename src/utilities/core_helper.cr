module ACAEngine::Api
  module Utils::CoreHelper
    def driver_execute(remote_driver, method, args)
      render json: remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: logger.request_id,
      )
    rescue e : Driver::Proxy::RemoteDriver::Error
      message = e.error_code.to_s.gsub('_', ' ')
      case e.error_code
      when Driver::Proxy::RemoteDriver::ErrorCode::ModuleNotFound,
           Driver::Proxy::RemoteDriver::ErrorCode::SystemNotFound
        logger.tag_info(message, error: e.message, sys_id: remote_driver.sys_id)
        render status: :not_found, text: message
      when Driver::Proxy::RemoteDriver::ErrorCode::ParseError,
           Driver::Proxy::RemoteDriver::ErrorCode::BadRequest,
           Driver::Proxy::RemoteDriver::ErrorCode::UnknownCommand
        logger.tag_error(message, error: e.message, sys_id: remote_driver.sys_id)
        render status: :bad_request, text: message
      when Driver::Proxy::RemoteDriver::ErrorCode::AccessDenied
        logger.tag_info(message)
        head :unauthorized
      when Driver::Proxy::RemoteDriver::ErrorCode::RequestFailed,
           Driver::Proxy::RemoteDriver::ErrorCode::UnexpectedFailure
        logger.tag_info(message, error: e.message, sys_id: remote_driver.sys_id)
        render status: :internal_server_error, text: message
      end
    rescue e
      logger.tag_error("core execute request failed", error: e.message, sys_id: remote_driver.sys_id, backtrace: e.inspect_with_backtrace)
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Determine user's Driver execution privilege
    def driver_clearance(user : Model::User | Model::UserJWT)
      if user.is_admin?
        Driver::Proxy::RemoteDriver::Clearance::Admin
      elsif user.is_support?
        Driver::Proxy::RemoteDriver::Clearance::Support
      else
        Driver::Proxy::RemoteDriver::Clearance::User
      end
    end

    def parse_module_slug(module_slug : String) : {String, Int32}?
      if module_slug.count('_') == 1
        module_name, index = module_slug.split('_')
        ({module_name, index.to_i})
      else
        logger.tag_error("malformed slug", module_slug: module_slug)
        head :bad_request
      end
    end
  end
end
