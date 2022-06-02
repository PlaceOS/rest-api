require "./application"

module PlaceOS::Api
  AUTH_TYPES = {"Ldap", "Saml", "OAuth"}
  {% for auth_type in AUTH_TYPES %}
    class {{auth_type.id}}Authentications < Application
      base "/api/engine/v2/{{auth_type.downcase.id}}_auths/"

      # Scopes
      ###############################################################################################

      before_action :can_read, only: [:index, :show]
      before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

      before_action :check_admin

      # Callbacks
      ###############################################################################################

      before_action :current_auth, only: [:show, :update, :update_alt, :destroy]
      before_action :body, only: [:create, :update, :update_alt]

      # Params
      ###############################################################################################

      getter authority_id : String? do
        params["authority_id"]?.presence || params["authority"]?.presence
      end

      ###############################################################################################

      getter current_auth : Model::{{auth_type.id}}Authentication do
        id = params["id"]
        Log.context.set({{auth_type.id.underscore}}_id: id)
        # Find will raise a 404 (not found) if there is an error
        Model::{{auth_type.id}}Authentication.find!(id, runopts: {"read_mode" => "majority"})
      end

      ###############################################################################################

      def index
        elastic = Model::{{auth_type.id}}Authentication.elastic
        query = elastic.query(params)

        if authority = authority_id
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
        current_auth.assign_attributes_from_json(self.body)
        save_and_respond current_auth
      end

      put_redirect

      def create
        save_and_respond(Model::{{auth_type.id}}Authentication.from_json(self.body))
      end

      def destroy
        current_auth.destroy
        head :ok
      end
    end
  {% end %}
end
