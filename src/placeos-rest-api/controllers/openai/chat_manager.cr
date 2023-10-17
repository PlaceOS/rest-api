require "tasker"
require "mutex"
require "openai"

module PlaceOS::Api
  class ChatGPT::ChatManager
    Log = ::Log.for(self)
    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    private getter ws_sockets = {} of UInt64 => {HTTP::WebSocket, String, OpenAI::Client, OpenAI::ChatCompletionRequest, OpenAI::FunctionExecutor}
    private getter ws_ping_tasks : Hash(UInt64, Tasker::Repeat(Nil)) = {} of UInt64 => Tasker::Repeat(Nil)

    private getter ws_lock = Mutex.new(protection: :reentrant)
    private getter app : ChatGPT

    LLM_DRIVER      = "LLM"
    LLM_DRIVER_CHAT = "new_chat"

    def initialize(@app)
    end

    def start_session(ws : HTTP::WebSocket, existing_chat : PlaceOS::Model::Chat?, system_id : String)
      ws_lock.synchronize do
        ws_id = ws.object_id
        if existing_socket = ws_sockets[ws_id]?
          existing_socket[0].close rescue nil
        end

        if chat = existing_chat
          Log.debug { {chat_id: chat.id, message: "resuming chat session"} }
          client, executor, chat_completion = setup(chat, nil)
          ws_sockets[ws_id] = {ws, chat.id.as(String), client, chat_completion, executor}
        else
          Log.debug { {message: "starting new chat session"} }
        end

        ws_ping_tasks[ws_id] = Tasker.every(10.seconds) do
          ws.ping rescue nil
          nil
        end

        ws.on_message { |message| manage_chat(ws, message, system_id) }

        ws.on_close do
          if task = ws_ping_tasks.delete(ws_id)
            task.cancel
          end
          ws_sockets.delete(ws_id)
        end
      end
    end

    private def manage_chat(ws : HTTP::WebSocket, message : String, system_id : String)
      ws_lock.synchronize do
        ws_id = ws.object_id
        _, chat_id, client, completion_req, executor = ws_sockets[ws_id]? || begin
          chat = PlaceOS::Model::Chat.create!(user_id: app.current_user.id.as(String), system_id: system_id, summary: message)
          id = chat.id.as(String)
          c, e, req = setup(chat, driver_prompt(chat))
          ws_sockets[ws_id] = {ws, id, c, req, e}
          {ws, id, c, req, e}
        end
        resp = openai_interaction(client, completion_req, executor, message, chat_id)
        ws.send(resp.to_json)
      end
    rescue error
      Log.warn(exception: error) { "failure processing chat message" }
      ws.send({message: "error: #{error}"}.to_json)
      ws.close
    end

    private def setup(chat, chat_payload)
      client = build_client
      executor = build_executor(chat, chat_payload)
      chat_completion = build_completion(build_prompt(chat, chat_payload), executor.functions)

      {client, executor, chat_completion}
    end

    private def build_client
      app_config = app.config
      config = if base = app_config.api_base
                 OpenAI::Client::Config.azure(api_key: app_config.api_key, api_base: base)
               else
                 OpenAI::Client::Config.default(api_key: app_config.api_key)
               end

      OpenAI::Client.new(config)
    end

    private def build_completion(messages, functions)
      OpenAI::ChatCompletionRequest.new(
        model: OpenAI::GPT4, # required for competent use of functions
        messages: messages,
        functions: functions,
        function_call: "auto"
      )
    end

    private def openai_interaction(client, request, executor, message, chat_id) : NamedTuple(chat_id: String, message: String?)
      request.messages << OpenAI::ChatMessage.new(role: :user, content: message)
      save_history(chat_id, :user, message)
      loop do
        resp = client.chat_completion(request)
        msg = resp.choices.first.message
        request.messages << msg
        save_history(chat_id, msg)

        if func_call = msg.function_call
          func_res = executor.execute(func_call)
          request.messages << func_res
          save_history(chat_id, msg)
          next
        end
        break {chat_id: chat_id, message: msg.content}
      end
    end

    private def save_history(chat_id : String, role : PlaceOS::Model::ChatMessage::Role, message : String, func_name : String? = nil, func_args : JSON::Any? = nil) : Nil
      PlaceOS::Model::ChatMessage.create!(role: role, chat_id: chat_id, content: message, function_name: func_name, function_args: func_args)
    end

    private def save_history(chat_id : String, msg : OpenAI::ChatMessage)
      save_history(chat_id, PlaceOS::Model::ChatMessage::Role.parse(msg.role.to_s), msg.content || "", msg.name, msg.function_call.try &.arguments)
    end

    private def build_prompt(chat : PlaceOS::Model::Chat, chat_payload : Payload?)
      messages = [] of OpenAI::ChatMessage

      if payload = chat_payload
        messages << OpenAI::ChatMessage.new(role: :system, content: payload.prompt)
        messages << OpenAI::ChatMessage.new(role: :system, content: "request function lists and call functions as required to fulfil requests.\n" +
                                                                    "make sure to interpret and reply with the results of function calls.\n" +
                                                                    "remember to only use valid capability ids, they can be found in this JSON:\n```json\n#{payload.capabilities.to_json}\n```" +
                                                                    "id strings are case sensitive and must not be modified.")

        messages.each { |m| save_history(chat.id.as(String), m) }
      else
        chat.messages.each do |hist|
          func_call = nil
          if hist.role.to_s == "function"
            if name = hist.function_name
              args = hist.function_args || JSON::Any.new(nil)
              func_call = OpenAI::ChatFunctionCall.new(name, args)
            end
          end
          messages << OpenAI::ChatMessage.new(role: OpenAI::ChatMessageRole.parse(hist.role.to_s), content: hist.content,
            name: hist.function_name,
            function_call: func_call
          )
        end
      end

      messages
    end

    private def driver_prompt(chat : PlaceOS::Model::Chat) : Payload?
      resp, code = exec_driver_func(chat, LLM_DRIVER, LLM_DRIVER_CHAT, nil)
      if code >= 200 && code <= 299
        Payload.from_json(resp)
      else
        raise "error obtaining chat prompt: #{resp} (#{code})"
      end
    end

    private def build_executor(chat, payload : Payload?)
      executor = OpenAI::FunctionExecutor.new

      description = if payload
                      "You have the following capability list, described in the following JSON:\n```json\n#{payload.capabilities.to_json}\n```\n" +
                        "if a request could benefit from these capabilities you can obtain the list of functions by providing the id string.\n" +
                        "id strings are case sensitive and must not be modified."
                    else
                      "if a request could benefit from a capability you can obtain the list of functions by providing the id string\n" +
                        "id strings are case sensitive and must not be modified."
                    end

      executor.add(
        name: "list_function_schemas",
        description: description,
        clz: FunctionDiscovery
      ) do |call|
        request = call.as(FunctionDiscovery)
        reply = "No response received"
        begin
          resp, code = exec_driver_func(chat, request.id, "function_schemas")
          reply = resp if 200 <= code <= 299
        rescue ex
          Log.error(exception: ex) { {id: request.id, function: "function_schemas"} }
          reply = "Encountered error: #{ex.message}"
        end
        DriverResponse.new(reply).as(JSON::Serializable)
      end

      executor.add(
        name: "call_function",
        description: "Executes functionality offered by a capability, you'll first need to obtain the function schema to perform a request",
        clz: FunctionExecutor) do |call|
        request = call.as(FunctionExecutor)
        reply = "No response received"
        begin
          resp, code = exec_driver_func(chat, request.id, request.function, request.parameters)
          reply = resp if 200 <= code <= 299
        rescue ex
          Log.error(exception: ex) { {id: request.id, function: request.function, args: request.parameters.to_s} }
          reply = "Encountered error: #{ex.message}"
        end
        DriverResponse.new(reply).as(JSON::Serializable)
      end

      executor
    end

    private def exec_driver_func(chat, module_name, method, args = nil)
      remote_driver = RemoteDriver.new(
        sys_id: chat.system_id,
        module_name: module_name,
        index: 1,
        discovery: app.class.core_discovery,
        user_id: chat.user_id,
      ) { |module_id|
        Model::Module.find!(module_id).edge_id.as(String)
      }

      remote_driver.exec(
        security: app.driver_clearance(app.user_token),
        function: method,
        args: args
      )
    end

    private struct FunctionExecutor
      extend OpenAI::FuncMarker
      include JSON::Serializable

      @[JSON::Field(description: "The ID of the capability, exactly as provided in the capability list")]
      getter id : String

      @[JSON::Field(description: "The name of the function")]
      getter function : String

      @[JSON::Field(description: "a JSON hash representing the named arguments of the function, as per the JSON schema provided")]
      getter parameters : JSON::Any?
    end

    private struct FunctionDiscovery
      extend OpenAI::FuncMarker
      include JSON::Serializable

      @[JSON::Field(description: "The ID of the capability, exactly as provided in the capability list")]
      getter id : String
    end

    private record DriverResponse, body : String do
      include JSON::Serializable
    end

    struct Payload
      include JSON::Serializable

      getter prompt : String
      getter capabilities : Array(Capabilities)
      getter system_id : String

      record Capabilities, id : String, capability : String do
        include JSON::Serializable
      end
    end
  end
end
