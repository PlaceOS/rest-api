require "./application"

module PlaceOS::Api
  # Assets, the individual physical items (each an instance of an asset type) tracked by zone, barcode and serial number
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

    # 404 unless the asset belongs to the caller's authority — resolved via
    # asset_type → category, the only tenanted link in the asset chain.
    # Legacy categories with no authority stay reachable (same adoption
    # semantics as AssetCategories#update). Applies to admin and support
    # users too. Declared before `confirm_access` so another authority's
    # asset is a 404 rather than a 403.
    @[AC::Route::Filter(:before_action, only: [:show, :update, :destroy])]
    private def confirm_authority
      raise Error::NotFound.new("asset #{current_asset.id} not found") unless owned_by_caller?(current_asset)
    end

    # a new or changed asset may only use an asset type of the caller's authority
    private def confirm_asset_type_authority(asset : ::PlaceOS::Model::Asset)
      raise Error::Forbidden.new("asset type #{asset.asset_type_id} belongs to another authority") unless owned_by_caller?(asset)
    end

    # whether the asset's type belongs to the caller's authority (or to a legacy category with no
    # authority). The type is looked up by id as the cached association is stale once an update
    # changes `asset_type_id`
    private def owned_by_caller?(asset : ::PlaceOS::Model::Asset) : Bool
      asset_type = asset.asset_type_id.try { |type_id| ::PlaceOS::Model::AssetType.find?(type_id) }
      owner = asset_type.try(&.category).try(&.authority_id)
      owner.nil? || owner == current_authority.as(::PlaceOS::Model::Authority).id
    end

    @[AC::Route::Filter(:before_action, only: [:update, :destroy])]
    private def confirm_access
      return if user_support?

      # "support" subsystem: the verb's bit on the asset's zone(s).
      asset_zones = ([current_asset.zone_id] + current_asset.zones).compact.uniq!
      return if support_subsystem_grants?(asset_zones, verb_permission)

      authority = current_authority.as(::PlaceOS::Model::Authority)

      if zone_id = authority.config["org_zone"]?.try(&.as_s?)
        zones = [zone_id, current_asset.zone_id].compact
        access = check_access(current_user.groups, zones)
        return if access.can_manage?
      end

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # List assets, filtered by the params provided.
    @[AC::Route::GET("/", converters: {zones: ConvertStringArray, features: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "only return assets whose zone_id field is this zone id", example: "zone-1234")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "comma separated zone ids; only return assets whose zones list contains every one of them", example: "zone-1234,zone-4567")]
      zones : Array(String)? = nil,
      @[AC::Param::Info(description: "only return assets of this asset type id", example: "asset_type-1234")]
      type_id : String? = nil,
      @[AC::Param::Info(description: "only return assets acquired on this asset purchase order id", example: "asset_purchase_order-1234")]
      order_id : String? = nil,
      @[AC::Param::Info(description: "only return assets with exactly this barcode", example: "1234567")]
      barcode : String? = nil,
      @[AC::Param::Info(description: "only return assets with exactly this serial number", example: "1234567")]
      serial_number : String? = nil,
      @[AC::Param::Info(description: "true returns only bookable assets, false only non-bookable assets; omit for both", example: "true")]
      bookable : Bool? = nil,
      @[AC::Param::Info(description: "true returns only accessible assets, false only non-accessible assets; omit for both", example: "false")]
      accessible : Bool? = nil,
      @[AC::Param::Info(description: "comma separated features; returns assets that have any of these features", example: "sit-to-stand,whiteboard")]
      features : Array(String)? = nil,
    ) : Array(::PlaceOS::Model::Asset)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::Asset.all

      # Callers only see assets belonging to their own authority (via
      # asset_type → category); legacy NULL-authority categories stay visible
      # (see `confirm_authority`).
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id
      query = query.where(
        "EXISTS (SELECT 1 FROM asset_type at JOIN asset_category ac ON ac.id = at.category_id WHERE at.id = asset.asset_type_id AND (ac.authority_id IS NULL OR ac.authority_id = ?))",
        authority_id
      )

      if zone_id
        query = query.where(zone_id: zone_id)
      end

      # asset must be in every one of the listed zones (parity with the
      # Elasticsearch AND-term semantics)
      if zones && !zones.empty?
        query = query.where("zones @> #{sql_array(zones)}", zones)
      end

      if type_id
        query = query.where(asset_type_id: type_id)
      end

      if order_id
        query = query.where(purchase_order_id: order_id)
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

    # Get a single asset.
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Asset
      current_asset
    end

    # Update an asset with the fields in the request body and return the saved asset.
    @[AC::Route::PATCH("/:id", body: :asset)]
    @[AC::Route::PUT("/:id", body: :asset)]
    def update(asset : ::PlaceOS::Model::Asset) : ::PlaceOS::Model::Asset
      current = current_asset
      current.assign_attributes(asset)
      confirm_asset_type_authority(current)
      # re-check after assignment so the destination zone(s) of a move are
      # authorised too, not just the zones the asset started in
      confirm_access
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # Create an asset.
    @[AC::Route::POST("/", body: :asset, status_code: HTTP::Status::CREATED)]
    def create(asset : ::PlaceOS::Model::Asset) : ::PlaceOS::Model::Asset
      @current_asset = asset
      confirm_asset_type_authority(asset)
      confirm_access
      raise Error::ModelValidation.new(asset.errors) unless asset.save
      asset
    end

    # Delete an asset.
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_asset.destroy
    end

    # Bulk actions
    ###############################################################################################

    # Create several assets; the body is a JSON array of assets.
    @[AC::Route::POST("/bulk", body: :assets, status_code: HTTP::Status::CREATED)]
    def bulk_create(assets : Array(::PlaceOS::Model::Asset)) : Array(::PlaceOS::Model::Asset)
      assets.map do |asset|
        @current_asset = asset
        confirm_asset_type_authority(asset)
        confirm_access
        raise Error::ModelValidation.new(asset.errors) unless asset.save
        asset
      end
    end

    # Update several assets; the body is a JSON array of assets, each with its `id`.
    @[AC::Route::PATCH("/bulk", body: :assets)]
    @[AC::Route::PUT("/bulk", body: :assets)]
    def bulk_update(assets : Array(::PlaceOS::Model::Asset)) : Array(::PlaceOS::Model::Asset)
      assets.compact_map do |asset|
        if asset_id = asset.id
          current = find_current_asset(asset_id)
          confirm_authority
          confirm_access
          current.assign_attributes(asset)
          confirm_asset_type_authority(current)
          # destination zones of a move must be authorised too
          confirm_access
          raise Error::ModelValidation.new(current.errors) unless current.save
          current
        end
      end
    end

    # Delete several assets; the body is a JSON array of asset ids.
    @[AC::Route::DELETE("/bulk", body: :asset_ids, status_code: HTTP::Status::ACCEPTED)]
    def bulk_destroy(asset_ids : Array(String)) : Nil
      asset_ids.each do |asset_id|
        current = find_current_asset(asset_id)
        confirm_authority
        confirm_access
        current.destroy
      end
    end
  end
end
