require "http"
require "placeos-models"

module PlaceOS::Api
  module Utils::Responders
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController

    # Write JSON to the response IO
    #
    macro render_json(status = :ok, &block)
      %response = @context.response
      %response.status = {{status}}
      %response.content_type = "application/json"
      JSON.build(%response) {{block}}
      @render_called = true
      return
    end

    # Renders API error messages in a consistent format
    #
    def render_error(status : HTTP::Status, message : String?, **additional)
      message = "API error" if message.nil?
      # render status: status, json: additional.merge({message: message})
      message = additional.merge({message: message})
      respond_with status, description: "render error" do
        json message
      end
    end

    # Shortcut to save a record and render a response
    #
    # Accepts an optional block to process the entity before response.
    def save_and_respond(resource)
      result, status = save_and_status(resource)

      if status.success? && result.is_a?(PlaceOS::Model::ModelBase)
        result = yield result
      end

      render status, json: result, type: result.class unless @render_called
    end

    # :ditto:
    def save_and_respond(resource)
      save_and_respond(resource) { resource }
    end

    # Shortcut to save a record and give the correct status
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
               in .module_not_found?, .system_not_found?
                 Log.info { error.message }
                 HTTP::Status::NOT_FOUND
               in .parse_error?, .bad_request?, .unknown_command?
                 Log.error { error.message }
                 HTTP::Status::BAD_REQUEST
               in .request_failed?, .unexpected_failure?
                 Log.info { error.message }
                 HTTP::Status::INTERNAL_SERVER_ERROR
               in .access_denied?
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
