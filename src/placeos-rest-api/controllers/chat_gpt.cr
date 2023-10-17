require "./application"

module PlaceOS::Api
  class ChatGPT < Application
    include Utils::CoreHelper
    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    base "/api/engine/v2/chatgpt/"

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:chat, :delete]

    @[AC::Route::Filter(:before_action)]
    def check_authority
      unless @authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end
    end

    getter chat_manager : ChatGPT::ChatManager { ChatGPT::ChatManager.new(self) }
    getter! authority : Model::Authority?

    # list user chats
    @[AC::Route::GET("/")]
    def index : Array(Model::Chat)
      Model::Chat.where(user_id: current_user.id.not_nil!).all.to_a
    end

    # show user chat history
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "id", description: "return the chat messages associated with this chat id", example: "chats-xxxx")]
      id : String
    ) : Array(NamedTuple(role: String, content: String?, timestamp: Time))
      unless chat = Model::Chat.find?(id)
        Log.warn { {message: "Invalid chat id. Unable to find matching chat history", id: id, user: current_user.id} }
        raise Error::NotFound.new("Invalid chat id: #{id}")
      end

      chat.messages.to_a.select!(&.role.in?([Model::ChatMessage::Role::User, Model::ChatMessage::Role::Assistant]))
        .map { |c| {role: c.role.to_s, content: c.content, timestamp: c.created_at} }
    end

    # the websocket endpoint for ChatGPT chatbot
    @[AC::Route::WebSocket("/chat/:system_id")]
    def chat(socket, system_id : String,
             @[AC::Param::Info(name: "resume", description: "To resume previous chat session. Provide session chat id", example: "chats-xxxx")]
             resume : String? = nil) : Nil
      chat_manager.start_session(socket, (resume && PlaceOS::Model::Chat.find!(resume.not_nil!)) || nil, system_id)
    rescue e : RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message, backtrace: e.backtrace)
    end

    # remove chat and associated history
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(id : String) : Nil
      unless chat = Model::Chat.find?(id)
        Log.warn { {message: "Invalid chat id. Unable to find matching chat record", id: id, user: current_user.id} }
        raise Error::NotFound.new("Invalid chat id: #{id}")
      end
      chat.destroy
    end

    record Config, api_key : String, api_base : String?

    protected def config
      if internals = authority.internals["openai"]
        key = internals["api_key"]?.try &.as_s || Api::OPENAI_API_KEY || raise Error::NotFound.new("missing openai api_key configuration")
        Config.new(key, internals["api_base"]?.try &.as_s || Api::OPENAI_API_BASE)
      else
        key = Api::OPENAI_API_KEY || raise Error::NotFound.new("missing openai api_key configuration")
        Config.new(key, Api::OPENAI_API_BASE)
      end
    end
  end
end

require "./openai/chat_manager"
