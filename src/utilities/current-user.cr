require "uri"

require "engine-models/authority"
require "engine-models/user"
require "engine-models/user-jwt"

module ACAEngine::Api
  # Helper to grab user and authority from a request
  module Utils::CurrentUser
    @user_token : Model::UserJWT?
    @current_user : Model::User?
    @current_authority : Model::Authority?

    # Parses, and validates JWT if present.
    # Throws Error::MissingBearer and JWT::Error.
    def authorize!
      return if @user_token

      token = acquire_token

      # Request must have a bearer token
      head :unauthorized unless token

      begin
        @user_token = user_token = Model::UserJWT.decode(token)
      rescue e : JWT::Error
        self.settings.logger.warn("bearer malformed: action=authorize! error=#{e.inspect}")
        # Request bearer was malformed
        head :unauthorized
      end

      unless (authority = current_authority)
        self.settings.logger.warn("authority not found: action=authorize! host=#{request.host}")
        head :unauthorized
      end

      # Token and authority domains must match
      token_domain_host = URI.parse(user_token.domain).host
      authority_domain_host = URI.parse(authority.domain.as(String)).host
      unless token_domain_host == authority_domain_host
        self.settings.logger.warn("authority domain does not match token's: action=authorize! token=#{user_token} authority=#{authority}")
        head :unauthorized
      end
    end

    # Obtains user referenced by user_token id
    def current_user : Model::User
      return @current_user.as(Model::User) unless @current_user.nil?

      @current_user = Model::User.find!(user_token.id)
    end

    # Obtains the authority for the request's host
    def current_authority : Model::Authority?
      return @current_authority.as(Model::Authority) unless @current_authority.nil?

      @current_authority = Model::Authority.find_by_domain(request.host)
    end

    # Getter for user_token
    def user_token : Model::UserJWT
      # FIXME: Remove when action-controller respects the ordering of route callbacks
      authorize! unless @user_token
      @user_token.as(Model::UserJWT)
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
      user_token.is_admin?
    end

    def is_support?
      user_token.is_support?
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
  end
end
