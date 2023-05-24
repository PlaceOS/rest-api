require "./application"

module PlaceOS::Api
  class AssetPurchaseOrders < Application
    base "/api/engine/v2/asset_purchase_orders/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_purchase_order(id : String)
      Log.context.set(asset_purchase_order_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset_purchase_order = Model::AssetPurchaseOrder.find!(id)
    end

    getter! current_asset_purchase_order : Model::AssetPurchaseOrder

    ###############################################################################################

    # list the asset purchase_orders
    @[AC::Route::GET("/")]
    def index : Array(Model::AssetPurchaseOrder)
      elastic = Model::AssetPurchaseOrder.elastic
      query = elastic.query(search_params)
      # query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # show the selected asset purchase_order
    @[AC::Route::GET("/:id")]
    def show : Model::AssetPurchaseOrder
      current_asset_purchase_order
    end

    # udpate asset purchase_order details
    @[AC::Route::PATCH("/:id", body: :asset_purchase_order)]
    @[AC::Route::PUT("/:id", body: :asset_purchase_order)]
    def update(asset_purchase_order : Model::AssetPurchaseOrder) : Model::AssetPurchaseOrder
      current = current_asset_purchase_order
      current.assign_attributes(asset_purchase_order)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset purchase_order
    @[AC::Route::POST("/", body: :asset_purchase_order, status_code: HTTP::Status::CREATED)]
    def create(asset_purchase_order : Model::AssetPurchaseOrder) : Model::AssetPurchaseOrder
      raise Error::ModelValidation.new(asset_purchase_order.errors) unless asset_purchase_order.save
      asset_purchase_order
    end

    # remove asset purchase_order
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset_purchase_order.destroy
    end
  end
end
