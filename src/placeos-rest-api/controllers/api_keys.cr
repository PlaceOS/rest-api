require "./application"

module PlaceOS::Api
  class ApiKeys < Application
    base "/api/engine/v2/api_keys/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_admin, except: :inspect_key

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :inspect_key])]
    def find_current_api_key(id : String)
      Log.context.set(api_key: id)
      # Find will raise a 404 (not found) if there is an error
      @current_api_key = ::PlaceOS::Model::ApiKey.find!(id)
    end

    getter! current_api_key : ::PlaceOS::Model::ApiKey

    ###############################################################################################

    # returns a list of the API keys associated with the provided domain, otherwise all domains
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "the ID of the domain to be listed", example: "auth-12345")]
      authority_id : String? = nil
    ) : Array(::PlaceOS::Model::ApiKey::PublicResponse)
      elastic = ::PlaceOS::Model::ApiKey.elastic
      query = elastic.query(search_params)

      if authority = authority_id
        query.filter({"authority_id" => [authority]})
      end

      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query).map(&.to_public_struct)
    end

    # returns the requested API key details
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::ApiKey::PublicResponse
      current_api_key.to_public_struct
    end

    # updates an API key name, description user or scopes
    @[AC::Route::PATCH("/:id", body: :api_key)]
    @[AC::Route::PUT("/:id", body: :api_key)]
    def update(api_key : ::PlaceOS::Model::ApiKey) : ::PlaceOS::Model::ApiKey::PublicResponse
      current = current_api_key
      current.assign_attributes(api_key)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current.to_public_struct
    end

    # create a new API key
    @[AC::Route::POST("/", body: :api_key, status_code: HTTP::Status::CREATED)]
    def create(api_key : ::PlaceOS::Model::ApiKey) : ::PlaceOS::Model::ApiKey::PublicResponse
      raise Error::ModelValidation.new(api_key.errors) unless api_key.save
      api_key.to_public_struct
    end

    # remove an API key
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_api_key.destroy
    end

    # obtain the a JSON JWT representation of the API key permissions
    @[AC::Route::GET("/inspect")]
    def inspect_key : ::PlaceOS::Model::UserJWT
      authorize!
    end
  end
end
