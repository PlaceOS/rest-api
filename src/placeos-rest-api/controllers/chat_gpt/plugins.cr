require "../application"
require "../chat_gpt"
require "./chat_manager"

module PlaceOS::Api
  class ChatGPT::Plugin < Application
    include Utils::CoreHelper
    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    base "/api/engine/v2/chatgpt/plugin/:system_id"

    @[AC::Route::Filter(:before_action)]
    def check_authority
      unless @authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end
    end

    getter! authority : Model::Authority?
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

    # obtain the list of capabilities that this API can provide, must be called if the user requests some related functionality, to abtain details of the current user such as their name and email address and the current local time of the user.
    @[AC::Route::GET("/capabilities")]
    def capabilities : Details
      user_id = current_user.id.as(String)
      user = Model::User.find!(user_id)

      if timezone = Model::ControlSystem.find!(system_id).timezone
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
      capability_id : String
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
    @[AC::Route::POST("/call_function/:capability_id/:function_name", body: :payload, status: {
      JSON::Any                 => HTTP::Status::OK,
      NamedTuple(error: String) => HTTP::Status::BAD_REQUEST,
    })]
    def call_function(
      @[AC::Param::Info(description: "The ID of the capability, exactly as provided in the capability list")]
      capability_id : String,
      @[AC::Param::Info(description: "The name of the function to call")]
      function_name : String,
      @[AC::Param::Info(description: "a JSON string representing the named arguments of the function, as per the JSON schema provided")]
      payload : NamedTuple(function_params: String)
    ) : NamedTuple(response: String) | RequestError
      user_id = current_user.id

      begin
        remote_driver = RemoteDriver.new(
          sys_id: system_id,
          module_name: capability_id,
          index: 1,
          discovery: Application.core_discovery,
          user_id: user_id,
        ) { |module_id|
          Model::Module.find!(module_id).edge_id.as(String)
        }

        resp, _code = remote_driver.exec(
          security: driver_clearance(user_token),
          function: function_name,
          args: JSON.parse(payload[:function_params])
        )

        {response: resp}
      rescue error
        Log.error(exception: error) { {id: capability_id, function: function_name, args: payload[:function_params]} }
        {error: "Encountered error: #{error.message}"}
      end
    end
  end
end
