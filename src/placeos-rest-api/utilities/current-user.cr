require "uri"

require "placeos-models/authority"
require "placeos-models/user"
require "placeos-models/user_jwt"
require "placeos-models/api_key"

module PlaceOS::Api
  # Helper to grab user and authority from a request

  module Utils::CurrentUser
    # Parses, and validates JWT if present.
    # Throws Error::MissingBearer and JWT::Error.

    protected def check_jwt_scope
      access = user_token.get_access("public")
      block_access = true

      if request.method.downcase == "get"
        block_access = !access.none?
      else
        block_access = !access.write?
      end

      if block_access
        Log.warn { {message: "unknown scope #{user_token.scope}", action: "authorize!", host: request.hostname, id: user_token.id} }
        raise Error::Unauthorized.new "valid scope required for access"
      end
    end

    def authorize! : Model::UserJWT
      unless (token = @user_token).nil?
        check_jwt_scope
        return token
      end

      # check for X-API-Key use
      if token = request.headers["X-API-Key"]? || params["api-key"]? || cookies["api-key"]?.try(&.value)
        begin
          api_key = Model::ApiKey.find_key!(token)
          user_token = api_key.build_jwt
          Log.context.set(api_key_id: api_key.id, api_key_name: api_key.name)
          ensure_matching_domain(user_token)
          @user_token = user_token
          check_jwt_scope
          return user_token
        rescue e
          Log.warn(exception: e) { {message: "bad or unknown X-API-Key", action: "authorize!"} }
          raise Error::Unauthorized.new "unknown X-API-Key"
        end
      end

      # Request must have a bearer token
      token = acquire_token
      raise Error::Unauthorized.new unless token

      begin
        @user_token = user_token = Model::UserJWT.decode(token)
      rescue e : JWT::Error
        Log.warn(exception: e) { {message: "bearer malformed", action: "authorize!"} }
        # Request bearer was malformed
        raise Error::Unauthorized.new "bearer malformed"
      end

      ensure_matching_domain(user_token)
      check_jwt_scope
      user_token
    rescue e
      # ensure that the user token is nil if this function ever errors.
      @user_token = nil
      raise e
    end

    protected def ensure_matching_domain(user_token)
      unless authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end

      # Token and authority domains must match
      token_domain_host = URI.parse(user_token.domain).host
      authority_domain_host = URI.parse(authority.domain.as(String)).host
      unless token_domain_host == authority_domain_host
        Log.warn { {message: "authority domain does not match token's", action: "authorize!", token_domain: user_token.domain, authority_domain: authority.domain} }
        raise Error::Unauthorized.new "authority domain does not match token's"
      end
    end

    def check_oauth_scope
      utoken = user_token
      unless utoken.public_scope?
        Log.warn { {message: "unknown scope #{utoken.scope}", action: "authorize!", host: request.hostname, id: utoken.id} }
        raise Error::Unauthorized.new "public scope required for access"
      end
    end

    # Obtains user referenced by user_token id
    getter current_user : Model::User { Model::User.find!(user_token.id) }

    # Obtains the authority for the request's host
    getter current_authority : Model::Authority? { Model::Authority.find_by_domain(request.hostname.as(String)) }

    # Getter for user_token
    getter user_token : Model::UserJWT { authorize! }

    # Read admin status from supplied request JWT
    def check_admin
      raise Error::Forbidden.new unless user_admin?
    end

    # Read support status from supplied request JWT
    def check_support
      raise Error::Forbidden.new unless user_support?
    end

    def user_admin?
      user_token.is_admin?
    end

    def user_support?
      token = user_token
      token.is_support? || token.is_admin?
    end

    # Pull JWT from...
    # - Authorization header
    # - "bearer_token" param
    protected def acquire_token : String?
      if token = request.headers["Authorization"]?
        token = token.lchop("Bearer ").lchop("Token ").rstrip
        token unless token.empty?
      elsif token = params["bearer_token"]?
        token.strip
      elsif token = cookies["bearer_token"]?.try(&.value)
        token.strip
      end
    end
  end
end
