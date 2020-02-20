require "./application"

module ACAEngine::Api
  AUTH_TYPES = {"Ldap", "Saml", "OAuth"}
  {% for auth_type in AUTH_TYPES %}
    class {{auth_type.id}}Authentications < Application
      base "/api/engine/v2/{{auth_type.downcase.id}}_auths/"

      before_action :check_admin, except: [:index, :show]
      before_action :check_support, only: [:index, :show]

      before_action :find_auth, only: [:show, :update, :destroy]

      @auth : Model::{{auth_type.id}}Authentication?

      def index
        elastic = Model::{{auth_type.id}}Authentication.elastic
        query = elastic.query(params)

        if authority = params["authority"]?
          query.filter({
            "authority_id" => [authority],
          })
        end

        query.sort(NAME_SORT_ASC)
        render json: paginate_results(elastic, query)
      end

      def show
        render json: current_auth
      end

      def update
        auth = current_auth
        auth.assign_attributes_from_json(request.body.as(IO))
        save_and_respond auth
      end

      # TODO: replace manual id with interpolated value from `id_param`
      put "/:id" { update }

      def create
        save_and_respond(Model::{{auth_type.id}}Authentication.from_json(request.body.as(IO)))
      end

      def destroy
        current_auth.destroy
        head :ok
      end

      #  Helpers
      ###########################################################################

      def current_auth : Model::{{auth_type.id}}Authentication
        @auth || find_auth
      end

      def find_auth
        # Find will raise a 404 (not found) if there is an error
        @auth = Model::{{auth_type.id}}Authentication.find!(params["id"]?)
      end
    end
  {% end %}
end
