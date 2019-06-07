require "./current_user"

module Engine::API
  module Utils::AuthorizationCallbacks
    def check_admin
      user = current_user.not_nil!
      head :forbidden unless user.sys_admin
    end

    def check_support
      user = current_user.not_nil!
      head :forbidden unless user.support
    end
  end
end
