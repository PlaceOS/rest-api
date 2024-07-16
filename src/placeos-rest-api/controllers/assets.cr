require "./application"

module PlaceOS::Api
  class Assets < Application
    include Utils::Permissions

    base "/api/engine/v2/assets/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :bulk_create, :bulk_update, :bulk_destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :bulk_create, :bulk_update, :bulk_destroy])]
    def find_current_asset(id : String)
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset = ::PlaceOS::Model::Asset.find!(id)
    end

    getter! current_asset : ::PlaceOS::Model::Asset

    @[AC::Route::Filter(:before_action, only: [:update, :destroy])]
    private def confirm_access
      return if user_support?

      authority = current_authority.as(::PlaceOS::Model::Authority)

      if zone_id = authority.config["org_zone"]?.try(&.as_s?)
        zones = [zone_id, current_asset.zone_id.as(String)]
        access = check_access(current_user.groups, zones)
        return if access.can_manage?
      end

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list the assets
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return assets which are in the zone provided", example: "zone-1234")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "return assets that match the asset type id provided", example: "asset_type-1234")]
      type_id : String? = nil,
      @[AC::Param::Info(description: "return assets that match the purchase order id provided", example: "asset_purchase_order-1234")]
      order_id : String? = nil,
      @[AC::Param::Info(description: "return assets that have a matchng barcode", example: "1234567")]
      barcode : String? = nil,
      @[AC::Param::Info(description: "return assets that have a matchng serial number", example: "1234567")]
      serial_number : String? = nil
    ) : Array(::PlaceOS::Model::Asset)
      elastic = ::PlaceOS::Model::Asset.elastic
      query = elastic.query(search_params)

      if zone_id
        query.must({
          "zone_id" => [zone_id],
        })
      end

      if type_id
        query.must({
          "asset_type_id" => [type_id],
        })
      end

      if order_id
        query.must({
          "purchase_order_id" => [order_id],
        })
      end

      if barcode
        query.must({
          "barcode" => [barcode],
        })
      end

      if serial_number
        query.must({
          "serial_number" => [serial_number],
        })
      end

      # query.has_parent(parent: ::PlaceOS::Model::AssetType, parent_index: ::PlaceOS::Model::AssetType.table_name)

      query.sort({"id" => {order: :asc}})
      paginate_results(elastic, query)
    end

    # show the selected asset
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Asset
      current_asset
    end

    # udpate asset details
    @[AC::Route::PATCH("/:id", body: :asset)]
    @[AC::Route::PUT("/:id", body: :asset)]
    def update(asset : ::PlaceOS::Model::Asset) : ::PlaceOS::Model::Asset
      current = current_asset
      current.assign_attributes(asset)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset
    @[AC::Route::POST("/", body: :asset, status_code: HTTP::Status::CREATED)]
    def create(asset : ::PlaceOS::Model::Asset) : ::PlaceOS::Model::Asset
      @current_asset = asset
      confirm_access
      raise Error::ModelValidation.new(asset.errors) unless asset.save
      asset
    end

    # remove asset
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset.destroy
    end

    # Bulk actions
    ###############################################################################################

    # add new assets
    @[AC::Route::POST("/bulk", body: :assets, status_code: HTTP::Status::CREATED)]
    def bulk_create(assets : Array(::PlaceOS::Model::Asset)) : Array(::PlaceOS::Model::Asset)
      assets.map do |asset|
        raise Error::ModelValidation.new(asset.errors) unless asset.save
        asset
      end
    end

    # udpate asset details
    @[AC::Route::PATCH("/bulk", body: :assets)]
    @[AC::Route::PUT("/bulk", body: :assets)]
    def bulk_update(assets : Array(::PlaceOS::Model::Asset)) : Array(::PlaceOS::Model::Asset)
      assets.compact_map do |asset|
        if asset_id = asset.id
          current = find_current_asset(asset_id)
          current.assign_attributes(asset)
          raise Error::ModelValidation.new(current.errors) unless current.save
          current
        end
      end
    end

    # remove assets
    @[AC::Route::DELETE("/bulk", body: :asset_ids, status_code: HTTP::Status::ACCEPTED)]
    def bulk_destroy(asset_ids : Array(String)) : Nil
      asset_ids.each do |asset_id|
        current = find_current_asset(asset_id)
        current.destroy
      end
    end
  end
end
