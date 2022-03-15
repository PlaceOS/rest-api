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

    getter current_instance : Model::AssetInstance { find_asset_inst }

    @[OpenAPI(
      <<-YAML
        summary: get all instances of asset
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      elastic = Model::AssetInstance.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: paginate_results(elastic, query), type: Array(Model::AssetInstance)
    end

    @[OpenAPI(
      <<-YAML
        summary: get a asset instance
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      render json: current_instance, type: Model::AssetInstance
    end

    @[OpenAPI(
      <<-YAML
        summary: Create a asset instance
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      instance = body_as Model::AssetInstance, constructor: :from_json
      save_and_respond(instance)
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a instance
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      current_instance.assign_attributes_from_json(body_raw Model::AssetInstance)
      save_and_respond(current_instance)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete an instance
        security:
        - bearerAuth: []
      YAML
    )]
    def destroy
      current_instance.destroy # expires the cache in after callback
      head :ok
    end

    # Helpers
    ###########################################################################

    protected def find_asset_inst
      id = params["id"]
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::AssetInstance.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
