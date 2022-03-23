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

    getter authority_id : String? do
      params["authority_id"]?.presence
    end

    ###############################################################################################

    getter current_api_key : Model::ApiKey do
      id = params["id"]
      Log.context.set(api_key: id)
      # Find will raise a 404 (not found) if there is an error
      Model::ApiKey.find!(id, runopts: {"read_mode" => "majority"})
    end

    ###############################################################################################

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

    def show
      render_json { |json| current_api_key.to_public_json(json) }
    end

    def update
      current_api_key.assign_attributes_from_json(self.body)
      save_and_respond(current_api_key) { show }
    end

    put_redirect

    def create
      save_and_respond(Model::ApiKey.from_json(self.body)) do |key|
        render_json(status: :created) { |json| key.to_public_json(json) }
      end
    end

    def destroy
      current_api_key.destroy
      head :ok
    end

    get "/inspect", :inspect_key do
      render json: authorize!
    end
  end
end
