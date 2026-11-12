require "./application"

module PlaceOS::Api
  @[AC::MCP(hide: true)]
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
    getter! authority : ::PlaceOS::Model::Authority?

    # list user chats
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::Chat)
      ::PlaceOS::Model::Chat.where(user_id: current_user.id.not_nil!).all.to_a
    end

    # show user chat history
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "return the chat messages associated with this chat id", example: "chats-xxxx")]
      id : String,
    ) : Array(NamedTuple(role: String, content: String?, timestamp: Time))
      chat = own_chat!(id)
      chat.messages.to_a.select!(&.role.in?([Model::ChatMessage::Role::User, ::PlaceOS::Model::ChatMessage::Role::Assistant]))
        .map { |c| {role: c.role.to_s, content: c.content, timestamp: c.created_at} }
    end

    # Resolved before the websocket upgrade so an unknown (or someone else's)
    # chat is refused with a 404 rather than after the socket is open.
    # Pinned to the primary: a chat created moments ago may not yet be on a
    # lagging replica, which would 404 and spawn a duplicate chat.
    @[AC::Route::Filter(:before_action, only: [:chat])]
    def find_resume_chat(resume : String? = nil)
      @resume_chat = on_primary { own_chat!(resume) } if resume
    end

    getter resume_chat : ::PlaceOS::Model::Chat? = nil

    # the websocket endpoint for ChatGPT chatbot
    @[AC::Route::WebSocket("/chat/:system_id")]
    def chat(
      socket,
      @[AC::Param::Info(description: "the system id the LLM driver resides", example: "sys-xxxx")]
      system_id : String,
      @[AC::Param::Info(description: "To resume previous chat session. Provide session chat id", example: "chats-xxxx")]
      resume : String? = nil,
    ) : Nil
      chat_manager.start_session(socket, resume_chat, system_id)
    rescue e : RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      render_error(HTTP::Status::INTERNAL_SERVER_ERROR, e.message, backtrace: e.backtrace)
    end

    # remove chat and associated history
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      @[AC::Param::Info(description: "the id of the chat to delete", example: "chats-xxxx")]
      id : String,
    ) : Nil
      own_chat!(id).destroy
    end

    # Chats hold the owner's history (and a system prompt with their contact
    # details), so only the owner may read, resume or delete one. Someone
    # else's chat is reported as missing rather than forbidden.
    private def own_chat!(id : String) : ::PlaceOS::Model::Chat
      chat = ::PlaceOS::Model::Chat.find?(id)
      unless chat && chat.user_id == current_user.id
        Log.warn { {message: "Invalid chat id. Unable to find matching chat for user", id: id, user: current_user.id} }
        raise Error::NotFound.new("Invalid chat id: #{id}")
      end
      chat
    end

    record Config, api_key : String, api_base : String?, max_tokens : Int32, api_model : String

    getter config : Config do
      if internals = authority.internals["openai"]?
        api_key = internals["api_key"]?.try &.as_s || Api::OPENAI_API_KEY || raise Error::NotFound.new("missing openai api_key configuration")
        api_base = internals["api_base"]?.try &.as_s || Api::OPENAI_API_BASE
        api_model = internals["api_model"]?.try &.as_s || Api::OPENAI_API_MODEL
        max_tokens = internals["max_tokens"]?.try &.as_i || Api::OPENAI_MAX_TOKENS

        Config.new(api_key, api_base, max_tokens, api_model)
      else
        api_key = Api::OPENAI_API_KEY || raise Error::NotFound.new("missing openai api_key configuration")
        Config.new(api_key, Api::OPENAI_API_BASE, Api::OPENAI_MAX_TOKENS, Api::OPENAI_API_MODEL)
      end
    end
  end
end

require "./chat_gpt/*"
