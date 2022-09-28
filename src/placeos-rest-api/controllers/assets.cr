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

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_asset(id : String)
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset = Model::Asset.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_asset : Model::Asset

    # Response helpers
    ###############################################################################################

    # extend the ControlSystem model to handle our return values
    class Model::Asset
      @[JSON::Field(key: "asset_instances")]
      property asset_instances_details : Array(PlaceOS::Model::AssetInstance)? = nil
    end

    ###############################################################################################

    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return assets that are a subset of this asset", example: "asset-12345")]
      parent_id : String? = nil
    ) : Array(Model::Asset)
      elastic = Model::Asset.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)

      # Limit results to the children of this parent
      if parent = parent_id
        query.must({
          "parent_id" => [parent],
        })
      end

      paginate_results(elastic, query)
    end

    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "instances", description: "return assets that are a subset of this asset?", example: "true")]
      include_instances : Bool = false
    ) : Model::Asset | Hash(String, Array(PlaceOS::Model::AssetInstance) | JSON::Any)
      current_asset.asset_instances_details = current_asset.asset_instances.to_a if include_instances
      current_asset
    end

    @[AC::Route::PATCH("/:id", body: :asset)]
    @[AC::Route::PUT("/:id", body: :asset)]
    def update(asset : Model::Asset) : Model::Asset
      current = current_asset
      current.assign_attributes(asset)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::POST("/", body: :asset, status_code: HTTP::Status::CREATED)]
    def create(asset : Model::Asset) : Model::Asset
      raise Error::ModelValidation.new(asset.errors) unless asset.save
      asset
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset.destroy # expires the cache in after callback
    end

    @[AC::Route::GET("/:id/asset_instances")]
    def asset_instances : Array(Model::AssetInstance)
      instances = current_asset.asset_instances.to_a
      set_collection_headers(instances.size, Model::AssetInstance.table_name)

      instances
    end
  end
end
