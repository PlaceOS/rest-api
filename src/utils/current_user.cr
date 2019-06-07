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
      # TODO: Ghost of ruby's past
      # user = cookies.encrypted[:user]

      # FIXME: Dummy until JWT implemented
      @current_user = Model::User.new(
        id: params["user_id"]? || "",
        email_digest: params["email_digest"]? || "",
        admin_status: params["admin_status"]? || "",
        social: params["social"]? || "",
      )

      return @current_user if @current_user
      @current_user = Model::User.find!((user[:id]))
    end

    def signed_in?
      !current_user.nil?
    end
  end
end
