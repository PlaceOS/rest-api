require "json"

module PlaceOS::Api
  module MCPModels
    # Protocol constants
    LATEST_PROTOCOL_VERSION             = "2025-06-18"
    DEFAULT_NEGOTIATED_PROTOCOL_VERSION = "2025-03-26"
    SUPPORTED_PROTOCOL_VERSIONS         = [
      LATEST_PROTOCOL_VERSION,
      "2025-03-26",
      "2024-11-05",
      "2024-10-07",
    ]

    JSONRPC_VERSION = "2.0"

    # Maximum size for incoming messages
    MAXIMUM_MESSAGE_SIZE = 4 * 1024 * 1024 # 4MB
    # Header names
    MCP_SESSION_ID_HEADER       = "mcp-session-id"
    MCP_PROTOCOL_VERSION_HEADER = "mcp-protocol-version"
    LAST_EVENT_ID_HEADER        = "last-event-id"

    # Content types
    CONTENT_TYPE_JSON = "application/json"
    CONTENT_TYPE_SSE  = "text/event-stream"

    # JSON-RPC types
    alias ProgressToken = String | Int64
    alias Cursor = String
    alias RequestId = String | Int64
    alias ContentBlock = TextContent | ImageContent | AudioContent | ResourceLink | EmbeddedResource
    EmptyJsonObject = Hash(String, JSON::Any).new
    # Enums for constrained values
    enum ErrorCode
      ConnectionClosed = -32000
      RequestTimeout   = -32001
      ParseError       = -32700
      InvalidRequest   = -32600
      MethodNotFound   = -32601
      InvalidParams    = -32602
      InternalError    = -32603
    end

    struct JSONRPCError
      include JSON::Serializable
      getter jsonrpc : String
      getter id : RequestId
      getter error : ErrorDetail

      def initialize(@id, @error, @jsonrpc = JSONRPC_VERSION)
      end

      def self.new(id : RequestId, code : ErrorCode, msg : String)
        details = ErrorDetail.new(code, msg)
        new(id, details)
      end
    end

    struct ErrorDetail
      include JSON::Serializable
      getter code : ErrorCode
      getter message : String
      getter data : JSON::Any?

      def initialize(@code, @message, @data = nil)
      end
    end

    abstract struct Result
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@meta = nil)
      end
    end

    struct JSONRPCResponse
      include JSON::Serializable
      getter jsonrpc : String
      getter id : RequestId
      getter result : Result

      def initialize(@id, @result, @jsonrpc = JSONRPC_VERSION)
      end
    end

    struct EmptyResult < Result
      def initialize
        super
      end
    end

    struct InitializeResult < Result
      @[JSON::Field(key: "protocolVersion")]
      getter protocol_version : String
      getter capabilities : ServerCapabilities
      @[JSON::Field(key: "serverInfo")]
      getter server_info : Implementation
      getter instructions : String?

      def initialize(@protocol_version, @capabilities, @server_info, @instructions = nil, @meta = nil)
      end
    end

    struct ListToolResult < Result
      getter tools : Array(Tool)
      @[JSON::Field(key: "nextCursor")]
      getter next_cursor : Cursor?

      def initialize(@tools, @next_cursor = nil, @meta = nil)
      end
    end

    struct CallToolResult < Result
      getter content : Array(ContentBlock)
      @[JSON::Field(key: "structuredContent")]
      getter structured_content : Hash(String, JSON::Any)?
      @[JSON::Field(key: "isError")]
      getter is_error : Bool?

      def initialize(@content = [] of ContentBlock, @structured_content = nil,
                     @is_error = nil, @meta = nil)
      end
    end

    struct Implementation
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter name : String
      getter version : String
      getter title : String?

      def initialize(@name, @version, @title = nil)
      end
    end

    struct ServerCapabilities
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter experimental : Hash(String, JSON::Any)?
      getter logging : Hash(String, JSON::Any)?
      getter completions : Hash(String, JSON::Any)?
      getter prompts : Capability?
      getter resources : Capability?
      getter tools : Capability?

      def initialize(@experimental = nil, @logging = nil, @completions = nil,
                     @prompts = nil, @resources = nil, @tools = nil)
      end

      def self.new_capability(list_changed : Bool, subscribe : Bool? = nil)
        Capability.new(list_changed, subscribe)
      end

      struct Capability
        include JSON::Serializable
        include JSON::Serializable::Unmapped
        getter subscribe : Bool?
        @[JSON::Field(key: "listChanged")]
        getter list_changed : Bool?

        def initialize(@list_changed = nil, @subscribe = nil)
        end
      end
    end

    struct TextContent
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter type : String
      getter text : String
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@text, @meta = nil, @type = "text")
      end
    end

    struct ImageContent
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter type : String
      getter data : String # Base64
      @[JSON::Field(key: "mimeType")]
      getter mime_type : String
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@data, @mime_type, @meta = nil, @type = "image")
      end
    end

    struct AudioContent
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter type : String
      getter data : String # Base64
      @[JSON::Field(key: "mimeType")]
      getter mime_type : String
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@data, @mime_type, @meta = nil, @type = "audio")
      end
    end

    struct EmbeddedResource
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter type : String
      getter resource : TextResourceContents | BlobResourceContents
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@resource, @meta = nil, @type = "resource")
      end
    end

    struct ResourceLink
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter type : String
      getter name : String
      getter uri : String
      getter description : String?
      getter title : String?
      @[JSON::Field(key: "mimeType")]
      getter mime_type : String?
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@name, @uri, @description = nil, @title = nil, @mime_type = nil, @meta = nil, @type = "resource_link")
      end
    end

    struct ToolSchema
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      @type : String
      getter properties : Hash(String, JSON::Any)?
      getter required : Array(String)?

      def initialize(@properties = EmptyJsonObject, @required = nil)
        @type = "object"
      end
    end

    struct ToolAnnotations
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter title : String?
      @[JSON::Field(key: "readOnlyHint")]
      getter read_only_hint : Bool?
      @[JSON::Field(key: "destructiveHint")]
      getter destructive_hint : Bool?
      @[JSON::Field(key: "idempotentHint")]
      getter idempotent_hint : Bool?
      @[JSON::Field(key: "openWorldHint")]
      getter open_world_hint : Bool?

      def initialize(@title = nil, @read_only_hint = nil, @destructive_hint = nil,
                     @idempotent_hint = nil, @open_world_hint = nil)
      end
    end

    struct Tool
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter name : String
      getter description : String?
      getter title : String?
      @[JSON::Field(key: "inputSchema")]
      getter input_schema : ToolSchema
      @[JSON::Field(key: "outputSchema")]
      getter output_schema : ToolSchema?
      getter annotations : ToolAnnotations?
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@name, @input_schema, @title = nil, @description = nil,
                     @output_schema = nil, @annotations = nil, @meta = nil)
      end
    end

    abstract struct ResourceContents
      include JSON::Serializable
      include JSON::Serializable::Unmapped
      getter uri : String
      @[JSON::Field(key: "mimeType")]
      getter mime_type : String?
      @[JSON::Field(key: "_meta")]
      getter meta : Hash(String, JSON::Any)?

      def initialize(@uri, @mime_type = nil, @meta = nil)
      end
    end

    struct TextResourceContents < ResourceContents
      getter text : String

      def initialize(uri, text, mime_type = nil, meta = nil)
        super(uri, mime_type, meta)
        @text = text
      end
    end

    struct BlobResourceContents < ResourceContents
      getter blob : String # Base64 encoded

      def initialize(uri, blob, mime_type = nil, meta = nil)
        super(uri, mime_type, meta)
        @blob = blob
      end
    end
  end
end
