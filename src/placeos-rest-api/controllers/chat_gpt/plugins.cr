require "../application"
require "../chat_gpt"

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

    alias FunctionSchema = NamedTuple(function: String, description: String, parameters: Hash(String, JSON::Any))

    # if a request could benefit from a capability, obtain the list of function schemas by providing the id string
    @[AC::Route::GET("/function_schema/:id")]
    def function_schema(
      @[AC::Param::Info(description: "The ID of the capability, exactly as provided in the capability list")]
      id : String
    ) : Array(FunctionSchema)
      module_name, index = RemoteDriver.get_parts(id)

      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: system_id,
        module_name: module_name,
        index: index
      )

      raise "error obtaining capability, #{id} not found on system #{system_id}" unless module_id

      storage = Driver::RedisStorage.new(module_id)
      Array(FunctionSchema).from_json storage["function_schemas"]
    end

    alias RequestError = NamedTuple(error: String)

    # Executes functionality offered by a capability, you'll need to obtain the function schema to perform requests
    @[AC::Route::GET("/call_function/:id/:function", body: :parameters, status: {
      JSON::Any                 => HTTP::Status::OK,
      NamedTuple(error: String) => HTTP::Status::BAD_REQUEST,
    })]
    def call_function(
      @[AC::Param::Info(description: "The ID of the capability, exactly as provided in the capability list")]
      id : String,
      @[AC::Param::Info(description: "The name of the function to call")]
      function : String,
      @[AC::Param::Info(description: "a JSON hash representing the named arguments of the function, as per the JSON schema provided")]
      parameters : JSON::Any
    ) : JSON::Any | RequestError
      user_id = current_user.id

      begin
        remote_driver = RemoteDriver.new(
          sys_id: system_id,
          module_name: id,
          index: 1,
          discovery: Application.core_discovery,
          user_id: user_id,
        ) { |module_id|
          Model::Module.find!(module_id).edge_id.as(String)
        }

        resp, _code = remote_driver.exec(
          security: driver_clearance(user_token),
          function: function,
          args: parameters
        )

        JSON.parse(resp)
      rescue error
        Log.error(exception: error) { {id: id, function: function, args: parameters.to_s} }
        {error: "Encountered error: #{error.message}"}
      end
    end
  end
end
