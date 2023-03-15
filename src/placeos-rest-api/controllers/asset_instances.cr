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

    ###########################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_instance(id : String)
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_instance = Model::AssetInstance.find!(id)
    end

    getter! current_instance : Model::AssetInstance

    ###########################################################################

    # return a list of the assets in the database
    @[AC::Route::GET("/")]
    def index : Array(Model::AssetInstance)
      elastic = Model::AssetInstance.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)

      paginate_results(elastic, query)
    end

    # return the details of an asset
    @[AC::Route::GET("/:id")]
    def show : Model::AssetInstance
      current_instance
    end

    # add a new asset to the database
    @[AC::Route::POST("/", body: :instance, status_code: HTTP::Status::CREATED)]
    def create(instance : Model::AssetInstance) : Model::AssetInstance
      raise Error::ModelValidation.new(instance.errors) unless instance.save
      instance
    end

    # update an assets details
    @[AC::Route::PATCH("/:id", body: :instance)]
    @[AC::Route::PUT("/:id", body: :instance)]
    def update(instance : Model::AssetInstance) : Model::AssetInstance
      current = current_instance
      current.assign_attributes(instance)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # remove an asset
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      # expires the cache in after callback
      current_instance.destroy
    end
  end
end
