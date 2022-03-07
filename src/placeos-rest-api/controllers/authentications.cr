require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  AUTH_TYPES = {"Ldap", "Saml", "OAuth"}
  {% for auth_type in AUTH_TYPES %}
    {% auth_model = "Model::#{auth_type.id}Authentication".id %}

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

      getter current_auth : {{ auth_model }} { find_auth }

      @[OpenAPI(
      <<-YAML
        summary: get all {{auth_type.id}} auths
        security:
        - bearerAuth: []
      YAML
    )]
      def index
        elastic = {{ auth_model }}.elastic
        query = elastic.query(params)

        if authority = authority_id
          query.filter({
            "authority_id" => [authority],
          })
        end

        query.sort(NAME_SORT_ASC)
        render json: paginate_results(elastic, query)
      end

      @[OpenAPI(
      <<-YAML
        summary: get current {{auth_type.id}} auths
        security:
        - bearerAuth: []
      YAML
    )]
      def show
        render json: current_auth
      end

      @[OpenAPI(
      <<-YAML
        summary: Update the current auth
        requestBody:
          required: true
          content:
            #{Schema.ref {{ auth_model }}}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref {{ auth_model }}}
      YAML
    )]
      def update
        current_auth.assign_attributes_from_json(self.body)
        save_and_respond current_auth
      end

      put_redirect

      def create
        save_and_respond({{ auth_model }}.from_json(self.body))
      end

      @[OpenAPI(
      <<-YAML
        summary: Delete a the current auth
        security:
        - bearerAuth: []
      YAML
    )]
      def destroy
        current_auth.destroy
        head :ok
      end

      #  Helpers
      ###########################################################################

      protected def find_auth
        id = params["id"]
        Log.context.set({{auth_type.id.underscore}}_id: id)
        # Find will raise a 404 (not found) if there is an error
        {{ auth_model }}.find!(id, runopts: {"read_mode" => "majority"})
      end
    end
  {% end %}
end
