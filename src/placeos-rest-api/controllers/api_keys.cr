require "./application"

module PlaceOS::Api
  class Edges < Application
    base "/api/engine/v2/api_keys/"

    before_action :check_admin
    before_action :body, only: [:create, :update, :update_alt]

    getter current_api_key : Model::ApiKey { find_api_key }

    def index
      elastic = Model::ApiKey.elastic
      query = elastic.query(params)

      authority_id = params["authority_id"]?
      query.filter({"authority_id" => [authority_id]}) if authority_id

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

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::ApiKey.from_json(self.body)) do |result|
        @current_api_key = result
        show
      end
    end

    def destroy
      current_api_key.destroy
      head :ok
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
