require "engine-models"

module Engine::API
  # Helpers to grab user from token
  module Utils::CurrentAuthority
    @current_authority : Model::Authority?

    def current_authority
      return @current_authority unless @current_authority.nil?

      authority = Model::Authority.find_by_domain(request.host)
      head :not_found unless authority
      @current_authority = authority
    end
  end
end
