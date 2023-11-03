require "tasker"
require "mutex"
require "openai"
require "placeos-driver/storage"

module PlaceOS::Api
  class ChatGPT::ChatManager
    Log = ::Log.for(self)
    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    private getter ws_sockets = {} of UInt64 => {HTTP::WebSocket, String, OpenAI::Client, OpenAI::ChatCompletionRequest, OpenAI::FunctionExecutor}
    private getter ws_ping_tasks : Hash(UInt64, Tasker::Repeat(Nil)) = {} of UInt64 => Tasker::Repeat(Nil)

    private getter ws_lock = Mutex.new(protection: :reentrant)
    private getter app : ChatGPT

    LLM_DRIVER        = "LLM"
    LLM_DRIVER_PROMPT = "prompt"

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
      if timezone = Model::ControlSystem.find!(system_id).timezone
        now = Time.local(timezone)
        message = "sent at: #{now}\nday of week: #{now.day_of_week}\n#{message}"
      end

      ws_lock.synchronize do
        ws_id = ws.object_id
        _, chat_id, client, completion_req, executor = ws_sockets[ws_id]? || begin
          chat = PlaceOS::Model::Chat.create!(user_id: app.current_user.id.as(String), system_id: system_id, summary: message)
          id = chat.id.as(String)
          c, e, req = setup(chat, driver_prompt(chat))
          ws_sockets[ws_id] = {ws, id, c, req, e}
          {ws, id, c, req, e}
        end
        openai_interaction(client, completion_req, executor, message, chat_id) do |resp|
          ws.send(resp.to_json)
        end
      end
    rescue error
      Log.warn(exception: error) { "failure processing chat message" }
      ws.send({message: "error: #{error}"}.to_json)
      ws.close
    end

    private def setup(chat, chat_payload)
      client = build_client
      executor = build_executor(chat)
      chat_completion = build_completion(build_prompt(chat, chat_payload), executor.functions)

      {client, executor, chat_completion}
    end

    private def build_client
      app_config = app.config

      # we save 10% of the tokens to hold the latest request and new output, should be enough
      @max_tokens = (app_config.max_tokens.to_f * 0.90).to_i

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

    @max_tokens : Int32 = 0
    @total_tokens : Int32 = 0

    # ameba:disable Metrics/CyclomaticComplexity
    private def openai_interaction(client, request, executor, message, chat_id, &) : Nil
      request.messages << OpenAI::ChatMessage.new(role: :user, content: message)

      # track token usage
      discardable_tokens = 0
      tracking_total = 0
      calculate_discard = false
      save_initial_msg = true

      # ensure we don't loop forever
      count = 0
      loop do
        count += 1
        if count > 20
          yield({chat_id: chat_id, message: "sorry, I am unable to complete that task", type: :response})
          request.messages.truncate(0..0) # leave only the prompt
          break
        end

        # cleanup old messages, saving first system prompt and then removing messages beyond that until we're within the limit
        ensure_request_fits(request)

        # track token usage
        resp = client.chat_completion(request)

        if save_initial_msg
          save_initial_msg = false

          # the first request is actually the prompt + user message
          # we always want to keep the prompt so we need to guestimate how many tokens this user message actually contains
          # this doesn't need to be highly accurate
          if request.messages.size == 2
            calculate_initial_request_size(request, resp.usage)
            save_history(chat_id, :user, message, request.messages[1].tokens)
          else
            save_history(chat_id, :user, message, resp.usage.prompt_tokens - @total_tokens)
          end
        end
        @total_tokens = resp.usage.total_tokens

        if calculate_discard
          discardable_tokens += resp.usage.prompt_tokens - tracking_total
          calculate_discard = false
        end
        tracking_total = @total_tokens

        # save relevant history
        msg = resp.choices.first.message
        msg.tokens = resp.usage.completion_tokens
        request.messages << msg
        save_history(chat_id, msg) unless msg.function_call || (msg.role.function? && msg.name != "task_complete")

        # perform function calls until we get a response for the user
        if func_call = msg.function_call
          discardable_tokens += resp.usage.completion_tokens

          # handle the AI not providing a valid function name, we want it to retry
          func_res = begin
            executor.execute(func_call)
          rescue ex
            Log.error(exception: ex) { "executing function call" }
            reply = "Encountered error: #{ex.message}"
            result = DriverResponse.new(reply).as(JSON::Serializable)
            request.messages << OpenAI::ChatMessage.new(:function, result.to_pretty_json, func_call.name)
            next
          end

          # process the function result
          case func_res.name
          when "task_complete"
            cleanup_messages(request, discardable_tokens)
            discardable_tokens = 0
            summary = TaskCompleted.from_json func_call.arguments.as_s
            yield({chat_id: chat_id, message: "condensing progress: #{summary.details}", type: :progress, function: func_res.name, usage: resp.usage, compressed_usage: @total_tokens})
          when "list_function_schemas"
            calculate_discard = true
            discover = FunctionDiscovery.from_json func_call.arguments.as_s
            yield({chat_id: chat_id, message: "checking #{discover.id} capabilities", type: :progress, function: func_res.name, usage: resp.usage})
          when "call_function"
            calculate_discard = true
            execute = FunctionExecutor.from_json func_call.arguments.as_s
            yield({chat_id: chat_id, message: "performing action: #{execute.id}.#{execute.function}(#{execute.parameters})", type: :progress, function: func_res.name, usage: resp.usage})
          end
          request.messages << func_res
          next
        end

        cleanup_messages(request, discardable_tokens)
        yield({chat_id: chat_id, message: msg.content, type: :response, usage: resp.usage, compressed_usage: @total_tokens})
        break
      end
    end

    private def ensure_request_fits(request)
      return if @total_tokens < @max_tokens

      messages = request.messages

      # NOTE:: we need at least one user message in the request
      num_user = messages.count(&.role.user?)

      # let the LLM know some information has been removed
      if messages[1].role.user?
        # we inject a message to the AI to indicate that some messages have been removed
        messages.insert(1, OpenAI::ChatMessage.new(role: :system, content: "some earlier messages have been removed", tokens: 6))
        @total_tokens += 6
      end

      delete_at = 2

      loop do
        msg = messages.delete_at(delete_at)
        if msg.role.user?
          if num_user == 1
            messages.insert(delete_at, msg)
            delete_at += 1
            next
          end

          num_user -= 1
        end
        @total_tokens -= msg.tokens

        break if @total_tokens <= @max_tokens || messages[delete_at]?.nil?
      end
    end

    private def calculate_initial_request_size(request, usage)
      msg = request.messages.pop
      prompt = request.messages.pop

      prompt_size = prompt.content.as(String).count(' ')
      msg_size = msg.content.as(String).count(' ')

      token_part = usage.prompt_tokens / (prompt_size + msg_size)

      msg_tokens = (token_part * msg_size).to_i
      prompt_tokens = (token_part * prompt_size).to_i

      msg.tokens = msg_tokens
      prompt.tokens = prompt_tokens

      request.messages << prompt
      request.messages << msg
    end

    private def cleanup_messages(request, discardable_tokens)
      # keep task summaries
      request.messages.reject! { |mess| mess.function_call || (mess.role.function? && mess.name != "task_complete") }

      # a good estimate of the total tokens once the cleanup is complete
      @total_tokens = @total_tokens - discardable_tokens
    end

    private def save_history(chat_id : String, role : PlaceOS::Model::ChatMessage::Role, message : String, tokens : Int32, func_name : String? = nil, func_args : JSON::Any? = nil) : Nil
      PlaceOS::Model::ChatMessage.create!(role: role, chat_id: chat_id, content: message, tokens: tokens, function_name: func_name, function_args: func_args)
    end

    private def save_history(chat_id : String, msg : OpenAI::ChatMessage)
      save_history(chat_id, PlaceOS::Model::ChatMessage::Role.parse(msg.role.to_s), msg.content || "", msg.tokens, msg.name, msg.function_call.try &.arguments)
    end

    private def build_prompt(chat : PlaceOS::Model::Chat, chat_payload : Payload?)
      messages = [] of OpenAI::ChatMessage

      if payload = chat_payload
        user = Model::User.find!(chat.user_id)

        messages << OpenAI::ChatMessage.new(
          role: :system,
          content: String.build { |str|
            str << payload.prompt
            str << "\n\nrequest function schemas and call functions as required to fulfil requests.\n"
            str << "make sure to interpret results and reply appropriately once you have all the information.\n"
            str << "remember to use valid capability ids, they can be found in this JSON:\n```json\n#{payload.capabilities.to_json}\n```\n\n"
            str << "you must have a schema for a function before calling it\n"
            str << "my name is: #{user.name}\n"
            str << "my email is: #{user.email}\n"
            str << "my phone number is: #{user.phone}\n" if user.phone.presence
            str << "my swipe card number is: #{user.card_number}\n" if user.card_number.presence
            str << "my user_id is: #{user.id}\n"
            str << "use these details in function calls as required.\n"
            str << "perform one task at a time, making as many function calls as required to complete a task. Once a task is complete call the task_complete function with details of the progress you've made.\n"
            str << "the chat client prepends the date-time each message was sent at in the following format YYYY-MM-DD HH:mm:ss +ZZ:ZZ:ZZ"
          }
        )

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
          messages << OpenAI::ChatMessage.new(
            role: OpenAI::ChatMessageRole.parse(hist.role.to_s),
            content: hist.content,
            name: hist.function_name,
            function_call: func_call,
            tokens: hist.tokens
          )
        end
      end

      messages
    end

    private def driver_prompt(chat : PlaceOS::Model::Chat) : Payload
      Payload.from_json grab_driver_status(chat, LLM_DRIVER, LLM_DRIVER_PROMPT)
    end

    private def build_executor(chat)
      executor = OpenAI::FunctionExecutor.new

      executor.add(
        name: "list_function_schemas",
        description: "if a request could benefit from a capability, obtain the list of function schemas by providing the id string",
        clz: FunctionDiscovery
      ) do |call|
        request = call.as(FunctionDiscovery)
        reply = "No response received"
        begin
          reply = grab_driver_status(chat, request.id, "function_schemas")
        rescue ex
          Log.error(exception: ex) { {id: request.id, status: "function_schemas"} }
          reply = "Encountered error: #{ex.message}"
        end
        DriverResponse.new(reply).as(JSON::Serializable)
      end

      executor.add(
        name: "call_function",
        description: "Executes functionality offered by a capability, you'll need to obtain the function schema to perform requests",
        clz: FunctionExecutor
      ) do |call|
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

      executor.add(
        name: "task_complete",
        description: "Once a task is complete, call this function with the details that are relevant to the conversion. Provide enough detail so you don't perform the actions again and can formulate a response to the user",
        clz: TaskCompleted
      ) do |call|
        request = call.as(TaskCompleted)
        request.as(JSON::Serializable)
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

    private def grab_driver_status(chat, module_slug : String, key : String) : String
      module_name, index = RemoteDriver.get_parts(module_slug)

      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: chat.system_id,
        module_name: module_name,
        index: index
      )

      if module_id
        storage = Driver::RedisStorage.new(module_id)
        storage[key]
      else
        raise "error obtaining chat prompt, #{module_slug} not found on system #{chat.system_id}"
      end
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

    private struct TaskCompleted
      extend OpenAI::FuncMarker
      include JSON::Serializable

      @[JSON::Field(description: "the details of the task that are relevant to continuing the conversion")]
      getter details : String
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
