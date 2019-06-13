require "engine-models"

module Engine::API
  # Helpers to grab user from token
  module Utils::CurrentUser
    @current_user : Model::User?

    # TODO: OAuth token with JWT field
    # Encode in JWT
    # - user's id
    # - email_digest
    # - admin_status
    # - social

    # TODO: Ghost of ruby's past
    # def remove_session
    #     cookies.delete(:user,   path: '/auth')
    #     cookies.delete(:social, path: '/auth')
    #     cookies.delete(:continue, path: '/auth')
    #     @current_user = nil
    # end

    def current_user
      return @current_user unless @current_user.nil?

      # TODO: Ghost of ruby's past
      # user = cookies.encrypted[:user]

      # FIXME: Dummy until JWT implemented
      @current_user = Model::User.new(
        id: params["user_id"]? || "",
        email_digest: params["email_digest"]? || "",
        sys_admin: !!(params["sys_admin"]?),
        support: !!(params["support"]?),
      )

      # TODO: On JWT
      # @current_user ||= Model::User.find!(token.user_id)
      @current_user
    end

    def signed_in?
      !current_user.nil?
    end
  end
end
