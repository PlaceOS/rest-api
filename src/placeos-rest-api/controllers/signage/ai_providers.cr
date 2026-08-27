require "placeos-models/signage_ai_provider"

require "../application"

module PlaceOS::Api
  # Vendor credentials for signage image generation.
  #
  # The Data Stores rule: sys_admin writes, support reads. Responses never carry
  # the credentials, so every route renders `as_json` rather than the row.
  class SignageAIProviders < Application
    base "/api/engine/v2/signage/ai/providers"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :test]

    before_action :check_admin, only: [:create, :update, :destroy, :test]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_provider(id : UUID)
      Log.context.set(signage_ai_provider: id.to_s)
      @current_provider = ::PlaceOS::Model::SignageAIProvider.find!(id)
    end

    getter! current_provider : ::PlaceOS::Model::SignageAIProvider

    # What a client may send. `credentials` is a JSON object whose shape depends
    # on the provider; it is required on create and, left out on update, the
    # stored value is kept.
    struct ProviderParams
      include JSON::Serializable

      getter name : String? = nil
      getter provider : String? = nil
      getter authority_id : String? = nil
      getter credentials : JSON::Any? = nil
      getter endpoint : String? = nil
      getter location : String? = nil
      getter default_model : String? = nil
      getter allowed_models : Array(String)? = nil
      getter enabled : Bool? = nil
      getter is_default : Bool? = nil
      getter quotas : JSON::Any? = nil
    end

    alias ProviderJSON = NamedTuple(
      id: String,
      name: String,
      provider: String,
      authority_id: String?,
      endpoint: String?,
      location: String?,
      default_model: String?,
      allowed_models: Array(String),
      enabled: Bool,
      is_default: Bool,
      quotas: JSON::Any,
      created_at: Int64,
      updated_at: Int64)

    # rows for a domain, or every row when no domain is given
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return the rows belonging to this authority", example: "authority-1234")]
      authority_id : String? = nil,
      @[AC::Param::Info(description: "include the shared fallback row", example: "true")]
      include_shared : Bool = true,
    ) : Array(ProviderJSON)
      rows = if authority_id
               if include_shared
                 ::PlaceOS::Model::SignageAIProvider.available_for(authority_id)
               else
                 ::PlaceOS::Model::SignageAIProvider.where(authority_id: authority_id).to_a
               end
             else
               ::PlaceOS::Model::SignageAIProvider.all.to_a
             end

      rows.map { |row| row.as_json }
    end

    @[AC::Route::GET("/:id")]
    def show : ProviderJSON
      current_provider.as_json
    end

    @[AC::Route::POST("/", body: :params, status_code: HTTP::Status::CREATED)]
    def create(params : ProviderParams) : ProviderJSON
      row = ::PlaceOS::Model::SignageAIProvider.new

      name = params.name
      raise Error::ModelValidation.new([Error::Field.new(:name, "is required")]) if name.nil? || name.empty?
      row.name = name

      row.provider = parse_provider(params.provider)

      credentials = params.credentials
      if credentials.nil? || credentials.as_h?.nil?
        raise Error::ModelValidation.new([Error::Field.new(:credentials, "must be a JSON object")])
      end
      row.credentials = credentials.to_json

      row.authority_id = params.authority_id
      apply_optional(row, params)

      raise Error::ModelValidation.new(row.errors) unless row.save
      row.as_json
    end

    @[AC::Route::PATCH("/:id", body: :params)]
    @[AC::Route::PUT("/:id", body: :params)]
    def update(params : ProviderParams) : ProviderJSON
      row = current_provider

      row.name = params.name.not_nil! if params.name.presence
      row.provider = parse_provider(params.provider) if params.provider.presence

      # left out (or blank) means keep what is stored
      if (credentials = params.credentials) && (hash = credentials.as_h?) && !hash.empty?
        row.credentials = credentials.to_json
      end

      apply_optional(row, params)

      raise Error::ModelValidation.new(row.errors) unless row.save
      row.as_json
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_provider.destroy
    end

    record TestResult, ok : Bool, latency_ms : Int64, model : String?, error : String? = nil, kind : String? = nil do
      include JSON::Serializable
    end

    # Prove a row's credentials work, without leaving anything behind: one small
    # image, discarded.
    @[AC::Route::POST("/:id/test")]
    def test : TestResult
      row = current_provider
      adapter = ImageGen::Adapter.for(row)
      model = row.default_model || adapter.capabilities.default_model

      started = Time.utc
      begin
        raise Error::ImageGen::NotConfigured.new("no model configured") if model.nil?

        adapter.generate(ImageGen::AdapterRequest.new(
          kind: ImageGen::Kind::Generate,
          prompt: "A plain mid grey background. No text, no logos, no objects.",
          aspect: "1:1",
          quality: "draft",
          candidates: 1,
          model: model,
        ))

        TestResult.new(ok: true, latency_ms: (Time.utc - started).total_milliseconds.to_i64, model: model)
      rescue ex : Error::ImageGen
        TestResult.new(false, (Time.utc - started).total_milliseconds.to_i64, model, ex.message, ex.kind)
      rescue ex
        TestResult.new(false, (Time.utc - started).total_milliseconds.to_i64, model, ex.message, "vendor")
      end
    end

    private def parse_provider(value : String?) : ::PlaceOS::Model::SignageAIProvider::Provider
      return ::PlaceOS::Model::SignageAIProvider::Provider::OPENAI if value.nil?
      ::PlaceOS::Model::SignageAIProvider::Provider.parse(value)
    rescue ArgumentError
      raise Error::ModelValidation.new([Error::Field.new(:provider, "must be one of OPENAI, AZURE_OPENAI, GOOGLE_VERTEX")])
    end

    # A field left out of the body is left alone; a field sent empty is cleared.
    # Without the second half an endpoint could be set but never unset, which
    # matters because an empty endpoint is what sends a provider to the vendor's
    # own host rather than to a gateway.
    private def apply_optional(row : ::PlaceOS::Model::SignageAIProvider, params : ProviderParams) : Nil
      row.endpoint = params.endpoint.try(&.presence) if params.endpoint
      row.location = params.location.try(&.presence) if params.location
      row.default_model = params.default_model.try(&.presence) if params.default_model
      row.allowed_models = params.allowed_models.not_nil! if params.allowed_models
      row.enabled = params.enabled.not_nil! unless params.enabled.nil?
      row.is_default = params.is_default.not_nil! unless params.is_default.nil?

      if (quotas = params.quotas) && quotas.as_h?
        row.quotas = quotas
      end
    end
  end
end
