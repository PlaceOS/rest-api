require "./application"

module PlaceOS::Api
  AUTH_TYPES = {"Ldap", "Saml", "OAuth"}
  {% for auth_type in AUTH_TYPES %}
    class {{auth_type.id}}Authentications < Application
      base "/api/engine/v2/{{auth_type.downcase.id}}_auths/"

      # Scopes
      ###############################################################################################

      before_action :can_read, only: [:index, :show]
      before_action :can_write, only: [:create, :update, :destroy, :remove]

      before_action :check_admin

      # Callbacks
      ###############################################################################################

      @[AC::Route::Filter(:before_action, except: [:index, :create])]
      def find_current_auth(id : String)
        Log.context.set({{auth_type.id.underscore}}_id: id)
        # Find will raise a 404 (not found) if there is an error
        @current_auth = ::PlaceOS::Model::{{auth_type.id}}Authentication.find!(id)
      end

      getter! current_auth : ::PlaceOS::Model::{{auth_type.id}}Authentication

      ###############################################################################################

      # returns a list of authentications
      @[AC::Route::GET("/")]
      def index(
        @[AC::Param::Info(description: "return authentications that belong to the provided domain", example: "auth-12345")]
        authority_id : String? = nil,
      ) : Array(::PlaceOS::Model::{{auth_type.id}}Authentication)
        elastic = ::PlaceOS::Model::{{auth_type.id}}Authentication.elastic
        query = elastic.query(search_params)

        if authority = authority_id
          query.filter({
            "authority_id" => [authority],
          })
        end

        query.sort(NAME_SORT_ASC)
        paginate_results(elastic, query)
      end

      # returns the details of a particular authentication
      @[AC::Route::GET("/:id")]
      def show : ::PlaceOS::Model::{{auth_type.id}}Authentication
        current_auth
      end

      # updates the details of an authentication
      @[AC::Route::PATCH("/:id", body: :auth)]
      @[AC::Route::PUT("/:id", body: :auth)]
      def update(auth : ::PlaceOS::Model::{{auth_type.id}}Authentication) : ::PlaceOS::Model::{{auth_type.id}}Authentication
        current = current_auth
        current.assign_attributes(auth)
        raise Error::ModelValidation.new(current.errors) unless current.save
        current
      end

      # creates a new authentication method
      @[AC::Route::POST("/", body: :auth, status_code: HTTP::Status::CREATED)]
      def create(auth : ::PlaceOS::Model::{{auth_type.id}}Authentication) : ::PlaceOS::Model::{{auth_type.id}}Authentication
        raise Error::ModelValidation.new(auth.errors) unless auth.save
        auth
      end

      # removes an authentication method
      @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
      def destroy : Nil
        current_auth.destroy
      end
    end
  {% end %}
end
