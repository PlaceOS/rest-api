require "./application"

module PlaceOS::Api
  class ApiKeys < Application
    base "/api/engine/v2/api_keys/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :update_alt]

    before_action :check_admin, except: :inspect_key

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :inspect_key])]
    def find_current_api_key(id : String)
      Log.context.set(api_key: id)
      # Find will raise a 404 (not found) if there is an error
      @current_api_key = Model::ApiKey.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_api_key : Model::ApiKey

    ###############################################################################################

    # returns a list of the API keys associated with the provided domain, otherwise all domains
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "the ID of the domain to be listed", example: "auth-12345")]
      authority_id : String? = nil
    ) : Array(Model::ApiKey::PublicResponse)
      elastic = Model::ApiKey.elastic
      query = elastic.query(search_params)

      if authority = authority_id
        query.filter({"authority_id" => [authority]})
      end

      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query).map(&.to_public_struct)
    end

    @[AC::Route::GET("/:id")]
    def show : Model::ApiKey::PublicResponse
      current_api_key.to_public_struct
    end

    @[AC::Route::PATCH("/:id", body: :api_key)]
    @[AC::Route::PUT("/:id", body: :api_key)]
    def update(api_key : Model::ApiKey) : Model::ApiKey::PublicResponse
      current = current_api_key
      current.assign_attributes(api_key)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current.to_public_struct
    end

    @[AC::Route::POST("/", body: :api_key, status_code: HTTP::Status::CREATED)]
    def create(api_key : Model::ApiKey) : Model::ApiKey::PublicResponse
      raise Error::ModelValidation.new(api_key.errors) unless api_key.save
      api_key.to_public_struct
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_api_key.destroy
    end

    @[AC::Route::GET("/inspect")]
    def inspect_key : Model::UserJWT
      authorize!
    end
  end
end
