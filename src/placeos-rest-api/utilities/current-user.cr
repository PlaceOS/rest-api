require "uri"

require "placeos-models/authority"
require "placeos-models/user"
require "placeos-models/user_jwt"

module PlaceOS::Api
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
      raise Error::Unauthorized.new unless token

      begin
        @user_token = user_token = Model::UserJWT.decode(token)
      rescue e : JWT::Error
        Log.warn(exception: e) { {message: "bearer malformed", action: "authorize!"} }
        # Request bearer was malformed
        raise Error::Unauthorized.new "bearer malformed"
      end

      unless (authority = current_authority)
        Log.warn { {message: "authority not found", action: "authorize!", host: request.host} }
        raise Error::Unauthorized.new "authority not found"
      end

      # Token and authority domains must match
      token_domain_host = URI.parse(user_token.domain).host
      authority_domain_host = URI.parse(authority.domain.as(String)).host
      unless token_domain_host == authority_domain_host
        Log.warn { {message: "authority domain does not match token's", action: "authorize!", token_domain: user_token.aud, authority_domain: authority.domain} }
        raise Error::Unauthorized.new "authority domain does not match token's"
      end
    rescue e
      # ensure that the user token is nil if this function ever errors.
      @user_token = nil
      raise e
    end

    # Obtains user referenced by user_token id
    def current_user : Model::User
      return @current_user.as(Model::User) unless @current_user.nil?
      @current_user = Model::User.find!(user_token.id)
    end

    # Obtains the authority for the request's host
    def current_authority : Model::Authority?
      return @current_authority.as(Model::Authority) unless @current_authority.nil?
      @current_authority = Model::Authority.find_by_domain(request.host.as(String))
    end

    # Getter for user_token
    def user_token : Model::UserJWT
      # FIXME: Remove when action-controller respects the ordering of route callbacks
      authorize! unless @user_token
      @user_token.as(Model::UserJWT)
    end

    # Read admin status from supplied request JWT
    def check_admin
      raise Error::Forbidden.new unless is_admin?
    end

    # Read support status from supplied request JWT
    def check_support
      raise Error::Forbidden.new unless is_support?
    end

    def is_admin?
      user_token.is_admin?
    end

    def is_support?
      token = user_token
      token.is_support? || token.is_admin?
    end

    # Pull JWT from...
    # - Authorization header
    # - "bearer_token" param
    protected def acquire_token : String?
      if (token = request.headers["Authorization"]?)
        token = token.lchop("Bearer ").rstrip
        token unless token.empty?
      elsif (token = params["bearer_token"]?)
        token.strip
      elsif (token = cookies["bearer_token"]?.try(&.value))
        token.strip
      end
    end
  end
end
