require "./application"

module PlaceOS::Api
  class Assets < Application
    include Utils::Permissions
    include Utils::GroupPermissions

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

      # "support" subsystem: the verb's bit on the asset's zone(s).
      asset_zones = ([current_asset.zone_id] + current_asset.zones).compact.uniq!
      return if support_subsystem_grants?(asset_zones, verb_permission)

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
    @[AC::Route::GET("/", converters: {zones: ConvertStringArray, features: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "return assets which have the zone_id provided", example: "zone-1234")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "return assets which are in the zones provided", example: "zone-1234,zone-4567")]
      zones : Array(String)? = nil,
      @[AC::Param::Info(description: "return assets that match the asset type id provided", example: "asset_type-1234")]
      type_id : String? = nil,
      @[AC::Param::Info(description: "return assets that match the purchase order id provided", example: "asset_purchase_order-1234")]
      order_id : String? = nil,
      @[AC::Param::Info(description: "return assets that have a matchng barcode", example: "1234567")]
      barcode : String? = nil,
      @[AC::Param::Info(description: "return assets that have a matchng serial number", example: "1234567")]
      serial_number : String? = nil,
      @[AC::Param::Info(description: "return assets that are bookable or not", example: "true")]
      bookable : Bool? = nil,
      @[AC::Param::Info(description: "return assets that are accessible or not", example: "false")]
      accessible : Bool? = nil,
      @[AC::Param::Info(description: "return assets which have the features provided", example: "sit-to-stand,whiteboard")]
      features : Array(String)? = nil,
    ) : Array(::PlaceOS::Model::Asset)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::Asset.all

      if zone_id
        query = query.where(zone_id: zone_id)
      end

      # asset must be in every one of the listed zones (parity with the
      # Elasticsearch AND-term semantics)
      if zones && !zones.empty?
        query = query.where("zones @> #{sql_array(zones)}", zones)
      end

      # asset_type_id / purchase_order_id are bigint columns; a non-numeric id
      # can never match (the Elasticsearch term filter returned no results for
      # unknown ids, so short-circuit rather than erroring on the cast)
      if type_id
        if type_id_number = type_id.to_i64?
          query = query.where(asset_type_id: type_id_number)
        else
          set_collection_headers(0, ::PlaceOS::Model::Asset.table_name)
          return [] of ::PlaceOS::Model::Asset
        end
      end

      if order_id
        if order_id_number = order_id.to_i64?
          query = query.where(purchase_order_id: order_id_number)
        else
          set_collection_headers(0, ::PlaceOS::Model::Asset.table_name)
          return [] of ::PlaceOS::Model::Asset
        end
      end

      if barcode
        query = query.where(barcode: barcode)
      end

      if serial_number
        query = query.where(serial_number: serial_number)
      end

      unless bookable.nil?
        query = query.where(bookable: bookable)
      end

      unless accessible.nil?
        query = query.where(accessible: accessible)
      end

      # asset matches any of the listed features (parity with the
      # Elasticsearch should + minimum_should_match(1) OR semantics)
      if features && !features.empty?
        query = query.where("features && #{sql_array(features)}", features)
      end

      # searching also matches text on the asset's type (name, brand, model
      # number) — implements the previously commented-out has_parent(AssetType)
      # query, mirroring modules-by-driver search
      if tsq = search_tsquery
        query = query.where(
          "(search_vector @@ to_tsquery('simple', ?) OR EXISTS (SELECT 1 FROM asset_type at WHERE at.id = asset.asset_type_id AND at.search_vector @@ to_tsquery('simple', ?)))",
          tsq, tsq
        )
      end

      paginate_sql(
        query.order("name, id"),
        ::PlaceOS::Model::Asset.table_name,
        limit: search_limit,
        offset: search_offset,
      )
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
        @current_asset = asset
        confirm_access
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
          confirm_access
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
        confirm_access
        current.destroy
      end
    end
  end
end
