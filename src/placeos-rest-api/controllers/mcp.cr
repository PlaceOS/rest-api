require "./application"
require "./mcp/models"
require "./mcp/sse"

module PlaceOS::Api
  class MCP < Application
    include Utils::CoreHelper
    include MCPModels
    base "/api/engine/v2/mcp"

    alias SessionStream = Hash(String, SSE::Connection)
    class_getter session_streams : SessionStream = SessionStream.new

    class_getter session_store : Hash(String, String | Bool | Nil) = Hash(String, String | Bool | Nil).new

    add_responder("text/event-stream") { |_io, _result| }

    @[AC::Route::Filter(:before_action, only: [:handler])]
    def check_accept_headers
      accept = request.headers["accept"]? || ""
      accept_types = accept.strip.split(',')
      has_json = accept_types.any? { |media| media.strip.starts_with?(CONTENT_TYPE_JSON) }
      has_sse = accept_types.any? { |media| media.strip.starts_with?(CONTENT_TYPE_SSE) }

      render_error_resp("Not Acceptable: Client must accept both application/json and text/event-stream", :not_acceptable) unless has_json && has_sse
    end

    @[AC::Route::Filter(:before_action, only: [:index])]
    def check_accept_headers
      accept = request.headers["accept"]? || ""
      accept_types = accept.strip.split(',')
      has_sse = accept_types.any? { |media| media.strip.starts_with?(CONTENT_TYPE_SSE) }

      render_error_resp("Not Acceptable: Client must accept text/event-stream", :not_acceptable) unless has_sse
    end

    @[AC::Route::Filter(:before_action, only: [:handler])]
    def check_content_type
      content_type = request.headers["content-type"]? || ""
      valid = content_type.strip.split(',').any? { |media| media.strip == CONTENT_TYPE_JSON }
      render_error_resp("Unsupported Media Type: Content-Type must be application/json", :unsupported_media_type) unless valid
    end

    @[AC::Route::Filter(:before_action, except: [:destroy])]
    def validate_protocol_version
      return unless request.headers[MCP_SESSION_ID_HEADER]?
      protocol_version = request.headers[MCP_PROTOCOL_VERSION_HEADER] || DEFAULT_NEGOTIATED_PROTOCOL_VERSION
      unless protocol_version.in?(SUPPORTED_PROTOCOL_VERSIONS)
        supported_versions = SUPPORTED_PROTOCOL_VERSIONS.join(", ")
        render_error_resp("Bad Request: Unsupported protocol version: #{protocol_version}. Supported versions: #{supported_versions}", :bad_request)
      end
    end

    @[AC::Route::Filter(:before_action)]
    def validate_or_add_session
      mcp_session_id = session_store[MCP_SESSION_ID_HEADER]?
      request_mcp_session = request.headers[MCP_SESSION_ID_HEADER]?
      return render_error_resp("Bad Request: Missing session ID", :bad_request) if request_mcp_session.nil? && mcp_session_id

      render_error_resp("Not Found: Invalid or expired session ID", :bad_request) unless mcp_session_id == request_mcp_session
      if session_val = mcp_session_id
        response.headers[MCP_SESSION_ID_HEADER] = session_val.to_s
      end
    end

    # MCP Server HTTP Streamable endpoint
    @[AC::Route::POST("/:sys_id/:module_slug", body: :raw)]
    def handler(
      sys_id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String,
      raw : JSON::Any,
    )
      return render_error_resp("Payload Too Large: Message exceeds maximum size", :payload_too_large) if raw.to_json.size > MAXIMUM_MESSAGE_SIZE
      messages = raw.as_a? ? raw.as_a.map(&.as_h) : [raw.as_h]

      initialize_req = messages.any?(&.["method"]?.try &.as_s.== "initialize")
      if initialize_req
        return render_error_resp("Invalid Request: Server already initialized", :bad_request) if session_store[MCP_SESSION_ID_HEADER]?
        return render_error_resp("Invalid Request: Only one initialization request is allowed", :bad_request) if messages.size > 1

        session_val = UUID.random.to_s
        session_store[MCP_SESSION_ID_HEADER] = session_val
        response.headers[MCP_SESSION_ID_HEADER] = session_val
        render json: initialize_resp(messages.first).to_json
      end

      notifications = messages.select { |msg| msg["method"]?.try &.as_s.starts_with?("notifications/") }
      if notifications.size > 0
        notifications.each { |notification| Log.info { {message: "Receive notification", notification: notification.to_json} } }
        render :accepted
      end

      errors = messages.select { |msg| msg.has_key?("error") }
      if errors.size > 0
        errors.each { |error| Log.info { {message: "Receive error", error: error.to_json} } }
        render :accepted
      end

      result = [] of JSONRPCResponse
      messages.each do |rpc_request|
        method = rpc_request["method"].as_s
        if method == "ping"
          result << ping_resp(rpc_request)
        elsif method == "tools/list"
          resp = handle_tools_list(sys_id, module_slug, rpc_request["id"])
          if resp.is_a?(CallError)
            break render_error_resp(resp)
          end
          result << resp
        elsif method == "tools/call"
          result << handle_tools_call(sys_id, module_slug, rpc_request)
        end
      end

      render json: result
    end

    # MCP HTTP Streamable SSE connection requested by client for server to client communication
    @[AC::Route::GET("/:sys_id/:module_slug")]
    def index(sys_id : String,
              @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
              module_slug : String,)
      session_id = request.headers.get?(MCP_SESSION_ID_HEADER)
      return render_error_resp("Bad Request: #{MCP_SESSION_ID_HEADER} header is required", :bad_request) unless session_id
      return render_error_resp("Bad Request: #{MCP_SESSION_ID_HEADER} header must be a single value", :bad_request) if session_id && session_id.size > 1

      response.headers.add(MCP_SESSION_ID_HEADER, session_id.not_nil!)
      sess_key = "#{sys_id}|#{module_slug}|#{session_id}"
      return render_error_resp("Conflict: Only one SSE stream is allowed per session", :conflict, ErrorCode::ConnectionClosed) if self.class.session_streams.has_key?(sess_key)
      SSE.upgrade_response(response) do |conn|
        self.class.session_streams[sess_key] = conn
      end
    end

    # Deletes established session and closes SSE connection (if any)
    @[AC::Route::DELETE("/:sys_id/:module_slug")]
    def destroy(sys_id : String,
                @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
                module_slug : String,) : Nil
      session_id = request.headers.get?(MCP_SESSION_ID_HEADER)
      return render_error_resp("Bad Request: #{MCP_SESSION_ID_HEADER} header is required", :bad_request) unless session_id
      return render_error_resp("Bad Request: #{MCP_SESSION_ID_HEADER} header must be a single value", :bad_request) if session_id && session_id.size > 1

      sess_key = "#{sys_id}|#{module_slug}|#{session_id}"
      return render_error_resp("Bad Request: SSE session not found", :bad_request) unless self.class.session_streams.has_key?(sess_key)
      self.class.session_streams[sess_key].close
      session_store.delete(MCP_SESSION_ID_HEADER)
      render :ok
    end

    # MCP HTTP Streamable is only requested to suport POST/GET/DELETE methods. This method returns JSONRPC error and closes connection
    @[AC::Route::PUT("/:sys_id/:module_slug")]
    @[AC::Route::PATCH("/:sys_id/:module_slug")]
    def unsupported(
      sys_id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String,
    )
      header = HTTP::Headers{
        "Allow" => "GET, POST, DELETE",
      }

      render_error_resp("Method Not Allowed", :method_not_allowed, ErrorCode::ConnectionClosed, header)
    end

    private def ping_resp(req : Hash(String, JSON::Any)) : JSONRPCResponse
      req_id = req["id"].raw.is_a?(Number) ? req["id"].as_i64 : req["id"].as_s
      JSONRPCResponse.new(req_id, EmptyResult.new)
    end

    private def initialize_resp(client : Hash(String, JSON::Any))
      server_info = Implementation.new(name: Api::APP_NAME, version: Api::VERSION)
      req_id = client["id"].raw.is_a?(Number) ? client["id"].as_i64 : client["id"].as_s
      requested_version = client["params"]["protocolVersion"].as_s

      proto_version = requested_version.in?(SUPPORTED_PROTOCOL_VERSIONS) ? requested_version : DEFAULT_NEGOTIATED_PROTOCOL_VERSION
      capabilities = ServerCapabilities.new(tools: ServerCapabilities.new_capability(false))
      result = InitializeResult.new(proto_version, capabilities, server_info)

      JSONRPCResponse.new(req_id, result)
    end

    alias FunctionSchema = NamedTuple(function: String, description: String, parameters: Hash(String, JSON::Any))

    private def handle_tools_list(sys_id : String, module_slug : String, id : JSON::Any) : JSONRPCResponse | CallError
      req_id = id.raw.is_a?(Number) ? id.as_i64 : id.as_s
      resp = exec_func("function_schemas", sys_id, module_slug)
      if resp.is_a?(CallError)
        return resp.as(CallError)
      end

      schemas = Array(FunctionSchema).from_json(resp.as(String))

      tools = [] of Tool
      schemas.each do |schema|
        required = [] of String
        properties = {} of String => JSON::Any
        schema[:parameters].each do |param_name, param_spec|
          next unless param_hash = param_spec.as_h?

          prop_schema = {} of String => JSON::Any
          optional = false
          if any_of = param_hash["anyOf"]?
            types = any_of.as_a.map { |t| t["type"].as_s }
            optional = types.any? { |type| type.downcase == "null" }
            type = types.reject { |type| type.downcase == "null" }.first
            prop_schema["type"] = JSON::Any.new(type)
            selected_type = any_of.as_a.select { |val| val["type"].as_s == type && val.as_h.has_key?("format") }
            format = selected_type.empty? ? type.capitalize : selected_type.first["format"].as_s
            prop_schema["description"] = JSON::Any.new(format)
          else
            prop_schema["type"] = param_hash["type"]
            prop_schema["description"] = JSON::Any.new(param_hash["type"].as_s.capitalize)
            optional = false
          end

          properties[param_name] = JSON::Any.new(prop_schema)
          required << param_name unless optional
        end
        input_schema = ToolSchema.new(
          properties: properties,
          required: required.empty? ? nil : required
        )
        tool_name = schema[:function]
        title = tool_name.split('_').map(&.capitalize).join(" ")
        tools << Tool.new(name: tool_name, title: title, description: schema[:description], input_schema: input_schema)
      end

      JSONRPCResponse.new(req_id, ListToolResult.new(tools))
    end

    private def handle_tools_call(sys_id : String, module_slug : String, req : Hash(String, JSON::Any)) : JSONRPCResponse
      req_id = req["id"].raw.is_a?(Number) ? req["id"].as_i64 : req["id"].as_s
      result = if params = req["params"]?.try &.as_h?
                 method = params["name"]
                 args = params["arguments"]
                 resp = exec_func("function_schemas", sys_id, module_slug, args)
                 if resp.is_a?(CallError)
                   call_error = resp.as(CallError)
                   content = [] of ContentBlock
                   content << TextContent.new(call_error.error.error.message)
                   CallToolResult.new(content, is_error: true)
                 else
                   is_json = resp.strip.starts_with?("[") || resp.strip.starts_with?("{")
                   structured_content = JSON.parse(resp).as_h rescue nil if is_json
                   content = [] of ContentBlock
                   content << TextContent.new(resp)
                   CallToolResult.new(content, structured_content: structured_content)
                 end
               else
                 content = [] of ContentBlock
                 content << TextContent.new("Invalid tools/call. Missing params")
                 CallToolResult.new(content, is_error: true)
               end

      JSONRPCResponse.new(req_id, result)
    end

    private def session_store
      self.class.session_store
    end

    private def exec_func(method : String, sys_id : String, module_slug : String, args : JSON::Any? = nil) : String | CallError
      module_name, index = RemoteDriver.get_parts(module_slug)
      Log.context.set(module_name: module_name, index: index, method: method)

      remote_driver = RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        user_id: current_user.id,
      ) { |module_id|
        ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
      }

      response_text, status_code = remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )
      return response_text
    rescue e : RemoteDriver::Error
      handle_tool_list_execute_error(e)
    rescue e
      create_error(e.message || "Uknown Internal error", :internal_server_error, ErrorCode::InternalError)
    end

    record CallError, status_code : Symbol, error : JSONRPCError, headers : HTTP::Headers = HTTP::Headers.new

    private def create_error(message, status_code : Symbol, error_code = ErrorCode::InvalidRequest, headers = HTTP::Headers.new)
      error = JSONRPCError.new("server-error", error_code, message)
      CallError.new(status_code, error, headers)
    end

    private def render_error_resp(message, status_code : Symbol, error_code = ErrorCode::InvalidRequest, headers = HTTP::Headers.new)
      headers.add("Content-Type", CONTENT_TYPE_JSON)
      error = create_error(message, status_code, error_code, headers)
      render_error_resp(error)
    end

    private def render_error_resp(error : CallError)
      response.headers.merge!(error.headers)

      render ActionController::Responders::STATUS_CODES[error.status_code], json: error.error.to_json
    end

    private def handle_tool_list_execute_error(error : Driver::Proxy::RemoteDriver::Error)
      message = error.error_code.to_s.gsub('_', ' ')
      Log.context.set(
        error: message,
        sys_id: error.system_id,
        module_name: error.module_name,
        index: error.index,
        remote_backtrace: error.remote_backtrace,
      )

      status, error_code = case error.error_code
                           in DriverError::ModuleNotFound, DriverError::SystemNotFound
                             Log.info { error.message }
                             {:not_found, ErrorCode::InvalidRequest}
                           in DriverError::ParseError, DriverError::BadRequest, DriverError::UnknownCommand
                             Log.error { error.message }
                             {:bad_request, ErrorCode::InvalidRequest}
                           in DriverError::RequestFailed, DriverError::UnexpectedFailure
                             Log.info { error.message }
                             {:internal_server_error, ErrorCode::InternalError}
                           in DriverError::AccessDenied
                             Log.info { error.message }
                             {:unauthorized, ErrorCode::InvalidRequest}
                           end

      msg = {
        error:       message,
        sys_id:      error.system_id,
        module_name: error.module_name,
        index:       error.index,
        message:     error.message,
      }.to_json

      create_error(msg, status, error_code)
    end
  end
end
