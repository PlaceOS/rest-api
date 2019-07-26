require "../models"

module Engine::API
  # Helpers to grab user from token
  module Utils::CurrentAuthority
    @current_authority : Model::Authority?

    def current_authority : Model::Authority?
      return @current_authority.as(Model::Authority) unless @current_authority.nil?

      authority = Model::Authority.find_by_domain(request.host)
      head :not_found unless authority

      (@current_authority = authority).as(Model::Authority)
    end
  end
end
