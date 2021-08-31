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

    def can_scope_access?(scope, access)
      # ameba:disable Performance/AnyInsteadOfEmpty
      [user_token.public_scope?, user_token.guest_scope?, user_token.get_access(scope).includes? access].any?
    end

    macro can_scope_access!(scope, access)
      {% SCOPES << scope.resolve? unless SCOPES.includes? scope.resolve? %}
      raise Error::Forbidden.new unless can_scope_access? {{scope}}, {{access}}
    end

    macro can_scopes_access!(scopes, access)
      raise Error::Forbidden.new if !{{scopes}}.any? { |scope| can_scope_access? scope, {{access}} }
    end
  end
end
