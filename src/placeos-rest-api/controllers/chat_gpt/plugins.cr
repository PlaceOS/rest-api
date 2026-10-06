require "../application"
require "../chat_gpt"
require "./chat_manager"

module PlaceOS::Api
  # Gives you the capabilities of a PlaceOS system, such as a meeting room or building.
  # Call capabilities first: it describes what the system can do and who the user is,
  # including their name, email and local time. Then call function_schema for a
  # capability to see its functions, and call_function to run one. Calls are made as the
  # signed in user, with their permissions.
  @[AC::MCP(endpoint: true)]
  class ChatGPT::Plugin < Application
    include Utils::CoreHelper

    base "/api/engine/v2/chatgpt/plugin/:system_id"

    generate_scope_check("control")

    before_action :can_read_control, only: [:capabilities, :function_schema]
    before_action :can_write_control, only: [:call_function]

    @[AC::Route::Filter(:before_action)]
    def check_authority
      unless @authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end
    end

    # the system must exist, unknown ids are a 404
    @[AC::Route::Filter(:before_action)]
    def find_control_system
      @control_system = ::PlaceOS::Model::ControlSystem.find!(system_id)
    end

    getter! authority : ::PlaceOS::Model::Authority?
    getter! control_system : ::PlaceOS::Model::ControlSystem?
    getter system_id : String { route_params["system_id"] }

    class Details
      include JSON::Serializable

      getter prompt : String
      getter capabilities : Array(Capabilities)
      getter system_id : String
      property user_information : UserInformation?
      property current_time : Time?
      property day_of_week : String?

      record Capabilities, id : String, capability : String do
        include JSON::Serializable
      end

      record UserInformation, id : String, name : String, email : String, phone : String?, swipe_card_number : String? do
        include JSON::Serializable
      end
    end

    # obtain the list of capabilities that this API can provide, must be called if the user requests some related functionality, to obtain details of the current user such as their name and email address and the current local time of the user.
    @[AC::Route::GET("/capabilities")]
    def capabilities : Details
      user_id = current_user.id.as(String)
      user = ::PlaceOS::Model::User.find!(user_id)

      if timezone = control_system.timezone
        now = Time.local(timezone)
      end

      module_name, index = RemoteDriver.get_parts(ChatGPT::ChatManager::LLM_DRIVER)

      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: system_id,
        module_name: module_name,
        index: index
      )

      raise "error obtaining capabilities on system #{system_id}" unless module_id

      storage = Driver::RedisStorage.new(module_id)
      details = Details.from_json storage[ChatGPT::ChatManager::LLM_DRIVER_PROMPT]
      details.user_information = Details::UserInformation.new(user_id, user.name.as(String), user.email.to_s, user.phone.presence, user.card_number.presence)
      details.current_time = now
      details.day_of_week = now.try(&.day_of_week.to_s)
      details
    end

    alias FunctionSchema = NamedTuple(function: String, description: String, parameters: Hash(String, JSON::Any))

    # if a request could benefit from a capability, obtain the list of function schemas by providing the id string
    @[AC::Route::GET("/function_schema/:capability_id")]
    def function_schema(
      @[AC::Param::Info(description: "The ID of the capability, exactly as provided in the capability list")]
      capability_id : String,
    ) : Array(FunctionSchema)
      module_name, index = RemoteDriver.get_parts(capability_id)

      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: system_id,
        module_name: module_name,
        index: index
      )

      raise "error obtaining capability, #{capability_id} not found on system #{system_id}" unless module_id

      storage = Driver::RedisStorage.new(module_id)
      Array(FunctionSchema).from_json storage["function_schemas"]
    end

    alias RequestError = NamedTuple(error: String)

    # Executes functionality offered by a capability, you'll need to obtain the function schema to perform requests. Then to use this operation you'll need to provide the capability id and the function name params
    @[AC::MCP(read_only: true)]
    @[AC::Route::POST("/call_function/:capability_id/:function_name", body: :payload, status: {
      JSON::Any                 => HTTP::Status::OK,
      NamedTuple(error: String) => HTTP::Status::BAD_REQUEST,
    })]
    def call_function(
      @[AC::Param::Info(description: "The ID of the capability, exactly as provided in the capability list")]
      capability_id : String,
      @[AC::Param::Info(description: "The name of the function to call")]
      function_name : String,
      @[AC::Param::Info(description: "the named arguments of the function, as per the JSON schema provided, as an object or a JSON string")]
      payload : NamedTuple(function_params: String | Hash(String, JSON::Any)),
    ) : NamedTuple(response: String) | RequestError
      user_id = current_user.id
      function_params = payload[:function_params]
      args = function_params.is_a?(String) ? JSON.parse(function_params) : JSON::Any.new(function_params)

      begin
        module_name, index = RemoteDriver.get_parts(capability_id)
        remote_driver = RemoteDriver.new(
          sys_id: system_id,
          module_name: module_name,
          index: index,
          user_id: user_id,
        ) { |module_id|
          ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
        }

        resp, _code = remote_driver.exec(
          security: driver_clearance(user_token),
          function: function_name,
          args: args
        )

        {response: resp}
      rescue error
        Log.error(exception: error) { {id: capability_id, function: function_name, args: args.to_json} }
        {error: "Encountered error: #{error.message}"}
      end
    end
  end
end
