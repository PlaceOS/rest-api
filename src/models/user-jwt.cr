require "./base/jwt"

module Engine::Model
  class UserJWT < JWTBase
    property iss : String

    @[JSON::Field(converter: Time::EpochConverter)]
    property iat : Time

    @[JSON::Field(converter: Time::EpochConverter)]
    property exp : Time

    # property jti : String

    # Maps to authority domain
    property aud : String

    # Maps to user id
    property sub : String

    property user : Metadata

    class Metadata
      include JSON::Serializable
      property name : String
      property email : String
      property admin : Bool
      property support : Bool

      def initialize(@name, @email, @admin, @support)
      end
    end

    def initialize(@iss, @iat, @exp, @aud, @sub, @user)
    end

    def domain
      @aud
    end

    def id
      @sub
    end

    def is_admin?
      @user.admin
    end

    def is_support?
      @user.support
    end
  end
end
