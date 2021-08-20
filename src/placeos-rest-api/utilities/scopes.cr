require "placeos-models/user_jwt"

module PlaceOS::Api
  # Helpers to generate scope checks
  module Utils::Scopes
    macro included
      macro inherited
        ROUTE_RESOURCE = {{ @type.stringify.split("::").last.underscore }}
        __create_scope_checks__
      end
    end

    alias Access = PlaceOS::Model::UserJWT::Scope::Access

    macro __create_scope_checks__
      protected def can_write
        can_scope_access!(ROUTE_RESOURCE, Access::Write)
      end

      protected def can_read
        can_scope_access!(ROUTE_RESOURCE, Access::Read)
      end

      {% verbatim do %}
        macro generate_scope_check(*scopes)
          {% for scope in scopes %}
            protected def can_write_{{ scope.id }}
              can_scopes_access!([ROUTE_RESOURCE, {{ scope }}], Access::Write)
            end

            protected def can_read_{{ scope.id }}
              can_scopes_access!([ROUTE_RESOURCE, {{ scope }}], Access::Read)
            end
          {% end %}
        end

        generate_scope_check("guest")
      {% end %}
    end

    SCOPES = [] of String

    macro can_scope_access!(scope, access)
      {% SCOPES << scope unless SCOPES.includes? scope %}
      raise Error::Forbidden.new unless user_token.public_scope? || user_token.get_access({{ scope }}).includes? {{ access }}
    end

    macro can_scopes_access!(scopes, access)
      {% for scope in scopes %}
        can_scope_access!({{scope}}, {{access}})
      {% end %}
    end
  end
end
