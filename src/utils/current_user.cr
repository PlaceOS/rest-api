require "engine-models/user-jwt"

module Engine::API
  # Helpers to grab user from token
  module Utils::CurrentUser
    @user_token : Model::UserJWT?
    @current_user : Model::User?

    def user_token
      return @user_token.not_nil! unless @user_token.nil?
      parse_user_token!
    end

    # Unmarshall Bearer token, raise MissingBearer if a Bearer token isn't present
    def parse_user_token! : Model::UserJWT
      raise Error::MissingBearer.new unless (token = parse_user_token)
      token.not_nil!
    end

    def parse_user_token : Model::UserJWT?
      token = request.headers["Authorization"]?.try do |bearer|
        bearer.lchop("Bearer ").rstrip
      end

      @user_token = Model::UserJWT.decode(token) if token
    end

    # Read admin status from supplied request JWT
    def check_admin
      raise Error::Unauthorized.new unless is_admin?
    end

    # Read support status from supplied request JWT
    def check_support
      raise Error::Unauthorized.new unless is_support?
    end

    def is_admin?
      user_token.admin
    end

    def is_support?
      user_token.support
    end

    def current_user : Model::User
      return @current_user.not_nil! unless @current_user.nil?

      @current_user = Model::User.find!(user_token.id)
    end

    def signed_in?
      !current_user.nil?
    end
  end
end
