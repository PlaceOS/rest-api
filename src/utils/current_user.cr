require "engine-models/user"
require "engine-models/user-jwt"

module Engine::API
  # Helpers to grab user from token
  module Utils::CurrentUser
    @user_token : Model::UserJWT?
    @current_user : Model::User?

    # Parses, and validates JWT if present.
    # Throws Error::MissingBearer and JWT::Error.
    def authorize!
      return if @user_token

      token = acquire_token

      # Request must have a bearer token
      head :unauthorized unless token

      begin
        @user_token = Model::UserJWT.decode(token)
      rescue e : JWT::Error
        settings.logger.warn("action=authorize! error=#{ e.inspect }")
        # Request bearer was malformed
        head :unauthorized
      end
    end

    # Pull JWT from...
    # - Authorization header
    # - "bearer_token" param
    protected def acquire_token : String?
      if (token = request.headers["Authorization"]?)
        token.lchop("Bearer ").rstrip
      elsif (token = params["bearer_token"]?)
        token.strip
      end
    end

    # Getter for user_token
    def user_token
      # FIXME: Remove when action-controller respects the ordering of route callbacks
      authorize! unless @user_token
      @user_token.not_nil!
    end

    # Read admin status from supplied request JWT
    def check_admin
      raise Error::Unauthorized.new unless is_admin?
    end

    # Read support status from supplied request JWT
    def check_support
      raise Error::Unauthorized.new unless is_support?
    end

    def is_admin?
      !!(user_token.admin)
    end

    def is_support?
      !!(user_token.support)
    end

    # Obtains user referenced by user_token id
    def current_user : Model::User
      return @current_user.not_nil! unless @current_user.nil?

      @current_user = Model::User.find!(user_token.id)
    end
  end
end
