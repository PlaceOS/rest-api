require "./application"

module PlaceOS::Api
  class Assets < Application
    base "/api/engine/v2/assets/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset(id : Int64)
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset = Model::Asset.find!(id)
    end

    getter! current_asset : Model::Asset

    ###############################################################################################

    # list the assets
    @[AC::Route::GET("/")]
    def index : Array(Model::Asset)
      elastic = Model::Asset.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # show the selected asset
    @[AC::Route::GET("/:id")]
    def show : Model::Asset
      current_asset
    end

    # udpate asset details
    @[AC::Route::PATCH("/:id", body: :asset)]
    @[AC::Route::PUT("/:id", body: :asset)]
    def update(asset : Model::Asset) : Model::Asset
      current = current_asset
      current.assign_attributes(asset)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset
    @[AC::Route::POST("/", body: :asset, status_code: HTTP::Status::CREATED)]
    def create(asset : Model::Asset) : Model::Asset
      raise Error::ModelValidation.new(asset.errors) unless asset.save
      asset
    end

    # remove asset
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset.destroy
    end
  end
end
