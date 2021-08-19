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

    def authorize! : Model::UserJWT
      unless (token = @user_token).nil?
        return token
      end

      # check for X-API-Key use
      if (token = request.headers["X-API-Key"]?)
        begin
          @user_token = user_token = Model::ApiKey.find_key!(token).build_jwt
          return user_token
        rescue e
          Log.warn(exception: e) { {message: "bad or unknown X-API-Key", action: "authorize!"} }
          raise Error::Unauthorized.new "unknown X-API-Key"
        end
      end

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
      user_token
    rescue e
      # ensure that the user token is nil if this function ever errors.
      @user_token = nil
      raise e
    end

    # Obtains user referenced by user_token id
    getter current_user : Model::User { Model::User.find!(user_token.id) }

    # Obtains the authority for the request's host
    getter current_authority : Model::Authority? { Model::Authority.find_by_domain(request.hostname.as(String)) }

    # Getter for user_token
    getter user_token : Model::UserJWT { authorize! }

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

    macro inherited
      ROUTE_RESOURCE = {{ @type.stringify.split("::").last.underscore }}
    end

    protected def can_write
      can_scope_access!(ROUTE_RESOURCE, :write)
    end

    protected def can_read
      can_scope_access!(ROUTE_RESOURCE, :read)
    end

    macro generate_scope_check(*scopes)
      {% for scope in scopes %}
        protected def can_{{ scope }}_write
          can_scopes_access([ROUTE_RESOURCE, {{ scope }}], :write)
        end

        protected def can_{{ scope }}_read
          can_scopes_access([ROUTE_RESOURCE, {{ scope }}], :read)
        end
      {% end %}
    end

    generate_scope_check("guest")

    SCOPES = [] of String

    macro can_scope_access!(scope, access)
      {% SCOPES << scope unless SCOPE.contains? scope %}
      raise Error::Forbidden.new unless user_token.public_scope? || user_token.get_access(scope_name) == {{ access }})
    end

    macro can_scopes_access!(scopes, access)
      {% for scope in scopes %}
        can_scope_access!({{scopes}}, {{access}})
      {% end %}
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
