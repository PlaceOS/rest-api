require "./base/jwt"

module Engine::Model
  class UserJWT < JWTBase
    attribute id : String
    attribute email : String
    attribute admin : Bool
    attribute support : Bool

    validates :id, :email, :admin, :support, presence: true
  end
end
