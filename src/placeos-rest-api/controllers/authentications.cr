require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  AUTH_TYPES = {"Ldap", "Saml", "OAuth"}
  {% for auth_type in AUTH_TYPES %}
    class {{auth_type.id}}Authentications < Application
      include ::OpenAPI::Generator::Controller
      include ::OpenAPI::Generator::Helpers::ActionController
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

      ###############################################################################################

      getter current_auth : Model::{{auth_type.id}}Authentication { find_auth }

      @[OpenAPI(
      <<-YAML
        summary: get all {{auth_type.id}} auths
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Auth}
      YAML
    )]
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

      @[OpenAPI(
      <<-YAML
        summary: get current {{auth_type.id}} auths
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Auth}
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
            #{Schema.ref Auth}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Auth}
      YAML
    )]
      def update
        current_auth.assign_attributes_from_json(self.body)
        save_and_respond current_auth
      end

      # TODO: replace manual id with interpolated value from `id_param`
      put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
        summary: Update the current auth
        requestBody:
          required: true
          content:
            #{Schema.ref Auth}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Auth}
        YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a new {{auth_type.id}} auth
        requestBody:
          required: true
          content:
            #{Schema.ref Auth}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Auth}
      YAML
    )]
      def create
        save_and_respond(Model::{{auth_type.id}}Authentication.from_json(self.body))
      end

      @[OpenAPI(
      <<-YAML
        summary: Delete a the current auth
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
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
        Model::{{auth_type.id}}Authentication.find!(id, runopts: {"read_mode" => "majority"})
      end
    end
  {% end %}
end
