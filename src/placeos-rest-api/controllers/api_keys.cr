require "./application"

module PlaceOS::Api
  # API keys, long lived credentials that act as a user with a limited set of scopes
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

    # An API key, with its owner's admin view (never their credentials)
    struct Response
      include JSON::Serializable

      getter id : String?
      getter name : String
      getter description : String

      @[JSON::Field(converter: PlaceOS::Model::DBArrConverter(PlaceOS::Model::UserJWT::Scope))]
      getter scopes : Array(::PlaceOS::Model::UserJWT::Scope)

      getter permissions : ::PlaceOS::Model::UserJWT::Permissions?
      getter user_id : String?
      getter authority_id : String?

      @[JSON::Field(converter: PlaceOS::Model::Timestamps::EpochConverter, type: "integer", format: "Int64")]
      getter created_at : Time

      @[JSON::Field(converter: PlaceOS::Model::Timestamps::EpochConverter, type: "integer", format: "Int64")]
      getter updated_at : Time

      @[JSON::Field(converter: Time::EpochConverterOptional, type: "integer", format: "Int64")]
      getter expires_at : Time?

      # Only present in the create response, the key is not retrievable later
      getter x_api_key : String?

      getter user : ::PlaceOS::Model::User::AdminResponse?
      getter authority : ::PlaceOS::Model::Authority?

      def initialize(key : ::PlaceOS::Model::ApiKey)
        @id = key.id
        @name = key.name
        @description = key.description
        @scopes = key.scopes
        @permissions = key.permissions
        @user_id = key.user_id
        @authority_id = key.authority_id
        @created_at = key.created_at
        @updated_at = key.updated_at
        @expires_at = key.expires_at
        @x_api_key = key.x_api_key
        # not the model `PublicResponse`: its raw `Model::User` serialises
        # the password digest and SSO tokens
        @user = key.user.try(&.to_admin_struct)
        @authority = key.authority
      end
    end

    ###############################################################################################

    # returns a list of the API keys associated with the provided domain, otherwise all domains
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "the ID of the domain to be listed", example: "auth-12345")]
      authority_id : String? = nil,
    ) : Array(Response)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::ApiKey.all

      if authority = authority_id
        query = query.where(authority_id: authority)
      end

      paginate_search(query, ::PlaceOS::Model::ApiKey.table_name).map { |key| Response.new(key) }
    end

    # returns the requested API key details
    @[AC::Route::GET("/:id")]
    def show : Response
      Response.new(current_api_key)
    end

    # updates an API key name, description user or scopes
    @[AC::Route::PATCH("/:id", body: :api_key)]
    @[AC::Route::PUT("/:id", body: :api_key)]
    def update(api_key : ::PlaceOS::Model::ApiKey) : Response
      current = current_api_key
      current.assign_attributes(api_key)
      raise Error::ModelValidation.new(current.errors) unless current.save
      Response.new(current)
    end

    # create a new API key
    @[AC::Route::POST("/", body: :api_key, status_code: HTTP::Status::CREATED)]
    def create(api_key : ::PlaceOS::Model::ApiKey) : Response
      raise Error::ModelValidation.new(api_key.errors) unless api_key.save
      Response.new(api_key)
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
