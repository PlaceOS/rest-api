require "engine-models/user-jwt"

module Engine::API
  # Helpers to grab user from token
  module Utils::CurrentUser
    @user_token : Model::UserJWT?
    @current_user : Model::User?

    def user_token : Model::UserJWT
      return @user_token.not_nil! unless @user_token.nil?
      parse_user_token!.not_nil!
    end

    def parse_user_token
      token = request.headers["Authorization"]?.try do |bearer|
        bearer.lchop("Bearer ").rstrip
      end
      @user_token = Model::UserJWT.decode(token) if token
    end

    # Unmarshall Bearer token, render a 401 if token isn't present
    def parse_user_token!
      parse_user_token.tap { |token| render status: :unauthorized, text: "missing Bearer token" unless token }
    end

    def is_admin?
      user_token.admin
    end

    def is_support?
      user_token.support
    end

    # Read admin status from supplied request JWT
    def check_admin
      head :forbidden unless user_token.admin
    end

    # Read support status from supplied request JWT
    def check_support
      head :forbidden unless user_token.support
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
