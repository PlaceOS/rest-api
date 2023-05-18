require "./application"

module PlaceOS::Api
  class AssetTypes < Application
    base "/api/engine/v2/asset_types/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_type(id : String)
      Log.context.set(asset_type_id: id)
      @current_asset_type = Model::AssetType.find_by(id: id)
    end

    getter! current_asset_type : Model::AssetType

    ###############################################################################################

    # list the asset types
    @[AC::Route::GET("/")]
    def index : Array(Model::AssetType)
      elastic = Model::AssetType.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # show the selected asset type
    @[AC::Route::GET("/:id")]
    def show : Model::AssetType
      current_asset_type
    end

    # udpate asset type details
    @[AC::Route::PATCH("/:id", body: :asset_type)]
    @[AC::Route::PUT("/:id", body: :asset_type)]
    def update(asset_type : Model::AssetType) : Model::AssetType
      current = current_asset_type
      current.assign_attributes(asset_type)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset type
    @[AC::Route::POST("/", body: :asset_type, status_code: HTTP::Status::CREATED)]
    def create(asset_type : Model::AssetType) : Model::AssetType
      raise Error::ModelValidation.new(asset_type.errors) unless asset_type.save
      asset_type
    end

    # remove asset type
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset_type.destroy
    end
  end
end
