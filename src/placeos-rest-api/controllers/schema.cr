require "./application"

module PlaceOS::Api
  class Schema < Application
    base "/api/engine/v2/schema/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    getter current_schema : Model::JsonSchema do
      id = params["id"]
      Log.context.set(schema_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::JsonSchema.find!(id, runopts: {"read_mode" => "majority"})
    end

    ###############################################################################################

    def index
      elastic = Model::JsonSchema.elastic
      query = elastic.query(params)
      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_schema
    end

    def update
      current_schema.assign_attributes_from_json(self.body)
      save_and_respond(current_schema)
    end

    put_redirect

    def create
      schema = Model::JsonSchema.from_json(self.body)
      save_and_respond(schema)
    end

    def destroy
      current_schema.destroy
      head :ok
    end
  end
end
