require "./application"

module PlaceOS::Api
  class AssetPurchaseOrders < Application
    include Utils::Permissions
    include Utils::GroupPermissions

    base "/api/engine/v2/asset_purchase_orders/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    @[AC::Route::Filter(:before_action)]
    private def confirm_access
      return if user_support?

      authority = current_authority.as(::PlaceOS::Model::Authority)

      if zone_id = authority.config["org_zone"]?.try(&.as_s?)
        # "support" subsystem: Read on the org zone for GET (index/show),
        # otherwise the verb's bit (verb_permission maps GET to None, which
        # only a Manage grant would satisfy).
        required = request.method.in?("GET", "HEAD") ? ::PlaceOS::Model::Permissions::Read : verb_permission
        return if support_subsystem_grants?([zone_id], required)
        access = check_access(current_user.groups, [zone_id])
        return if access.can_manage?
      end

      head :forbidden
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_purchase_order(id : String)
      Log.context.set(asset_purchase_order_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset_purchase_order = ::PlaceOS::Model::AssetPurchaseOrder.find!(id)
    end

    getter! current_asset_purchase_order : ::PlaceOS::Model::AssetPurchaseOrder

    ###############################################################################################

    # list the asset purchase_orders
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::AssetPurchaseOrder)
      # PG full-text search (PPT-2644): q matches purchase_order_number and
      # invoice_number. The table has no name column so order by PO number
      # for a deterministic listing (Elasticsearch had no explicit sort here).
      paginate_search(
        ::PlaceOS::Model::AssetPurchaseOrder.all,
        ::PlaceOS::Model::AssetPurchaseOrder.table_name,
        order: "purchase_order_number, id",
      )
    end

    # show the selected asset purchase_order
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::AssetPurchaseOrder
      current_asset_purchase_order
    end

    # udpate asset purchase_order details
    @[AC::Route::PATCH("/:id", body: :asset_purchase_order)]
    @[AC::Route::PUT("/:id", body: :asset_purchase_order)]
    def update(asset_purchase_order : ::PlaceOS::Model::AssetPurchaseOrder) : ::PlaceOS::Model::AssetPurchaseOrder
      current = current_asset_purchase_order
      current.assign_attributes(asset_purchase_order)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset purchase_order
    @[AC::Route::POST("/", body: :asset_purchase_order, status_code: HTTP::Status::CREATED)]
    def create(asset_purchase_order : ::PlaceOS::Model::AssetPurchaseOrder) : ::PlaceOS::Model::AssetPurchaseOrder
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
