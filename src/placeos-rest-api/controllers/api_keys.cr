require "./application"

module PlaceOS::Api
  class ApiKeys < Application
    base "/api/engine/v2/api_keys/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :update_alt]

    before_action :check_admin, except: :inspect_key

    # Callbacks
    ###############################################################################################

    before_action :body, only: [:create, :update, :update_alt]

    # Params
    ###############################################################################################

    param_getter(authority_id : String?, "ID of domain API key is assigned to")

    ###############################################################################################

    getter current_api_key : Model::ApiKey { find_api_key }

    @[OpenAPI(
      <<-YAML
        summary: Get all API keys
      YAML
    )]
    def index
      elastic = Model::ApiKey.elastic
      query = elastic.query(params)

      if authority = authority_id
        query.filter({"authority_id" => [authority]})
      end

      query.sort(NAME_SORT_ASC)

      render_json do |json|
        json.array do
          paginate_results(elastic, query).each &.to_public_json(json)
        end
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: get current api key
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      render_json { |json| current_api_key.to_public_json(json) }
    end

    @[OpenAPI(
      <<-YAML
        summary: Update an api key
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      current_api_key.assign_attributes_from_json(body_raw Model::ApiKey)
      save_and_respond(current_api_key) { show }
    end

    put_redirect

    def create
      api_key = body_as Model::ApiKey, constructor: :from_json
      save_and_respond(api_key) do |key|
        render_json(status: :created) { |json| key.to_public_json(json) }
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete an api key
        security:
        - bearerAuth: []
      YAML
    )]
    def destroy
      current_api_key.destroy
      head :ok
    end

    get("/inspect", :inspect_key, annotations: @[OpenAPI(<<-YAML
    summary: Get the user token
    security:
    - bearerAuth: []
    YAML
    )]) do
      render json: authorize!
    end

    # Helpers
    ###########################################################################

    protected def find_api_key
      id = params["id"]
      Log.context.set(api_key: id)
      # Find will raise a 404 (not found) if there is an error
      Model::ApiKey.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
