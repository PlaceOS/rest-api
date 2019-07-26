require "./base/jwt"

module Engine::Model
  class UserJWT < JWTBase
    property id : String
    property email : String
    property admin : Bool
    property support : Bool

    def initialize(@id, @email, @admin, @support)
    end

    def is_admin?
      !!(@admin)
    end

    def is_support?
      !!(@support)
    end
  end
end
