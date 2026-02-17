require "uri"

require "placeos-models/authority"
require "placeos-models/user"
require "placeos-models/user_jwt"
require "placeos-models/api_key"

require "./ms-token-exchange"

module PlaceOS::Api
  # Helper to grab user and authority from a request

  module Utils::CurrentUser
    # Parses, and validates JWT if present.
    # Throws Error::MissingBearer and JWT::Error.

    def authorize! : ::PlaceOS::Model::UserJWT
      if token = @user_token
        return token
      end

      # check for X-API-Key use
      if token = request.headers["X-API-Key"]? || params["api-key"]? || cookies["api-key"]?.try(&.value)
        begin
          api_key = ::PlaceOS::Model::ApiKey.find_key!(token)
          user_token = api_key.build_jwt
          Log.context.set(api_key_id: api_key.id, api_key_name: api_key.name)
          ensure_matching_domain(user_token)
          @user_token = user_token
          @current_user = ::PlaceOS::Model::User.find(user_token.id)
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
        # peek the token to determine type
        token_info = Utils::MSTokenExchange.peek_token_info(token)
        if token_info.ms_token?
          user = Utils::MSTokenExchange.obtain_place_user(token, token_info)
          raise "MS token could not be exchanged" unless user
          @current_user = user
          @user_token = user_token = Model::UserJWT.new(
            iss: Model::UserJWT::ISSUER,
            iat: 5.minutes.ago,
            exp: 1.hour.from_now,
            domain: user.authority.as(Model::Authority).domain,
            id: user.id.as(String),
            user: Model::UserJWT::Metadata.new(
              name: user.name.as(String),
              email: user.email.to_s,
              # non admin permissions and no roles
            ),
          )
        else
          user_token = ::PlaceOS::Model::UserJWT.decode(token)
          if !user_token.guest_scope? && (user_model = ::PlaceOS::Model::User.find(user_token.id))
            logged_out_at = user_model.logged_out_at
            if logged_out_at && (logged_out_at >= user_token.iat)
              raise JWT::Error.new("logged out")
            end
            @current_user = user_model
          end

          @user_token = user_token
        end
      rescue e : JWT::Error
        Log.warn(exception: e) { {message: "bearer invalid", action: "authorize!"} }
        # Request bearer was malformed
        raise Error::Unauthorized.new(e.message || "bearer invalid")
      end

      ensure_matching_domain(user_token)
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

    @current_user : ::PlaceOS::Model::User? = nil

    # Obtains user referenced by user_token id
    def current_user : ::PlaceOS::Model::User
      user = @current_user
      return user if user

      # authorize sets current user
      @user_token || authorize!
      @current_user.as(::PlaceOS::Model::User)
    end

    # Obtains the authority for the request's host
    getter current_authority : ::PlaceOS::Model::Authority? { ::PlaceOS::Model::Authority.find_by_domain(request.hostname.as(String)) }

    # Getter for user_token
    getter user_token : ::PlaceOS::Model::UserJWT { authorize! }

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
