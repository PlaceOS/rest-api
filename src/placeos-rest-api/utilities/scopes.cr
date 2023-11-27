require "placeos-models/user_jwt"

module PlaceOS::Api
  # Helpers to generate scope checks
  module Utils::Scopes
    macro included
      {% verbatim do %}
        macro inherited
          ROUTE_RESOURCE = {{ @type.stringify.split("::").last.underscore }}
          __create_scope_checks__
        end
      {% end %}
    end

    alias Access = PlaceOS::Model::UserJWT::Scope::Access
    alias UserJWT = PlaceOS::Model::UserJWT

    def self.can_scope_access?(user_token : UserJWT, scope : String, access : Access)
      user_token.get_access("public").includes?(access) || user_token.get_access(scope).includes?(access)
    end

    def self.can_scopes_access!(user_token : UserJWT, scopes : Enumerable(String), access : Access)
      has_access = scopes.any? do |scope|
        can_scope_access?(user_token, scope, access)
      end

      unless has_access
        raise Error::Forbidden.new("User does not have #{access} access to #{scopes.join(", ")}")
      end
    end

    macro __create_scope_checks__
      protected def can_write
        can_scopes_access!([{{ROUTE_RESOURCE}}], Access::Write)
      end

      protected def can_read
        can_scopes_access!([{{ROUTE_RESOURCE}}], Access::Read)
      end

      {% verbatim do %}
        macro generate_scope_check(*scopes)
          {% for scope in scopes %}
            {% if scope.is_a? Path %}
              {% scope = scope.resolve %}
            {% end %}
            protected def can_write_{{ scope.gsub(/-/, "_").id }}
              can_scopes_access!([{{ROUTE_RESOURCE}}, {{ scope }}], Access::Write)
            end

            protected def can_read_{{ scope.gsub(/-/, "_").id }}
              can_scopes_access!([{{ROUTE_RESOURCE}}, {{ scope }}], Access::Read)
            end
          {% end %}
        end

        # Example:
        # `can_read_guest()` is called in the Metadata controller
        # This will successfully authenticate if the user JWT contains the scope `metadata.read` OR `guest.read`
        generate_scope_check("guest")
      {% end %}
    end

    SCOPES = ["public"]

    macro can_scope_access?(scope, access)
      {% SCOPES << scope unless SCOPES.includes? scope %}
      ::PlaceOS::Api::Utils::Scopes.can_scope_access?(user_token, {{scope}}, {{access}})
    end

    # NOTE: A user JWT only needs one scope present, if mulitple scopes are supplied, to successfully authenticate a route
    macro can_scopes_access!(scopes, access)
      {% for scope in scopes %}
        {% SCOPES << scope unless SCOPES.includes? scope %}
      {% end %}
      ::PlaceOS::Api::Utils::Scopes.can_scopes_access!(user_token, {{scopes}}, {{access}})
    end
  end
end
