require "./application"

module PlaceOS::Api
  class Assets < Application
    base "/api/engine/v2/assets/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    before_action :ensure_json, only: [:create]

    getter current_asset : Model::Asset { find_asset }

    # Params
    ###############################################################################################

    getter asset_id : String do
      params["id"]
    end

    getter parent_id : String? do
      params["parent_id"]?.presence || params["parent"]?.presence
    end

    # Routes
    ###############################################################################################

    def index
      elastic = Model::Asset.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      # Limit results to the children of this parent
      if parent = parent_id
        query.must({
          "parent_id" => [parent],
        })
      end

      render json: paginate_results(elastic, query)
    end

    def show
      include_instances = boolean_param("instances")
      render json: !include_instances ? current_asset : with_fields(current_asset, {
        :asset_instances => current_asset.asset_instances.to_a,
      })
    end

    def update
      current_asset.assign_attributes_from_json(self.body)
      save_and_respond(current_asset)
    end

    def create
      save_and_respond Model::Asset.from_json(self.body)
    end

    def destroy
      current_asset.destroy # expires the cache in after callback
      head :ok
    end

    get "/:id/asset_instances", :asset_instances do
      instances = current_asset.asset_instances.to_a
      set_collection_headers(instances.size, Model::AssetInstance.table_name)

      render json: instances
    end

    # Helpers
    ###########################################################################

    protected def find_asset
      Log.context.set(asset_id: asset_id)
      # Find will raise a 404 (not found) if there is an error
      Model::Asset.find!(asset_id, runopts: {"read_mode" => "majority"})
    end
  end
end
