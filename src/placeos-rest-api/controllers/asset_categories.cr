require "./application"

module PlaceOS::Api
  class AssetCategories < Application
    base "/api/engine/v2/asset_categories/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_category(id : String)
      Log.context.set(asset_category_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset_category = Model::AssetCategory.find!(id)
    end

    getter! current_asset_category : Model::AssetCategory

    ###############################################################################################

    # list the asset categories
    @[AC::Route::GET("/")]
    def index : Array(Model::AssetCategory)
      elastic = Model::AssetCategory.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # show the selected asset category
    @[AC::Route::GET("/:id")]
    def show : Model::AssetCategory
      current_asset_category
    end

    # udpate asset category details
    @[AC::Route::PATCH("/:id", body: :asset_category)]
    @[AC::Route::PUT("/:id", body: :asset_category)]
    def update(asset_category : Model::AssetCategory) : Model::AssetCategory
      current = current_asset_category
      current.assign_attributes(asset_category)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset category
    @[AC::Route::POST("/", body: :asset_category, status_code: HTTP::Status::CREATED)]
    def create(asset_category : Model::AssetCategory) : Model::AssetCategory
      raise Error::ModelValidation.new(asset_category.errors) unless asset_category.save
      asset_category
    end

    # remove asset category
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset_category.destroy
    end
  end
end
