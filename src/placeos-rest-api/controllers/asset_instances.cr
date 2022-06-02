require "./application"

module PlaceOS::Api
  class AssetInstances < Application
    base "/api/engine/v2/asset-instances/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:show]

    before_action :ensure_json, only: [:create]

    ###########################################################################

    getter current_instance : Model::AssetInstance do
      id = params["id"]
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::AssetInstance.find!(id, runopts: {"read_mode" => "majority"})
    end

    ###########################################################################

    def index
      elastic = Model::AssetInstance.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_instance
    end

    def create
      model = Model::AssetInstance.from_json(self.body)
      save_and_respond(model)
    end

    def update
      current_instance.assign_attributes_from_json(self.body)
      save_and_respond(current_instance)
    end

    def destroy
      current_instance.destroy # expires the cache in after callback
      head :ok
    end
  end
end
