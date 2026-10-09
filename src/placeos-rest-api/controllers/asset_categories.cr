require "./application"

module PlaceOS::Api
  # Asset categories, a hierarchy (via `parent_category_id`) at the top of categories > asset types > assets
  class AssetCategories < Application
    include Utils::Permissions
    include Utils::GroupPermissions

    base "/api/engine/v2/asset_categories/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    @[AC::Route::Filter(:before_action, only: [:create, :update, :destroy])]
    private def confirm_access
      return if user_support?

      authority = current_authority.as(::PlaceOS::Model::Authority)

      if zone_id = authority.config["org_zone"]?.try(&.as_s?)
        # "support" subsystem: the verb's bit on the org zone.
        return if support_subsystem_grants?([zone_id], verb_permission)
        access = check_access(current_user.groups, [zone_id])
        return if access.can_manage?
      end

      head :forbidden
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_category(id : String)
      Log.context.set(asset_category_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset_category = ::PlaceOS::Model::AssetCategory.find!(id)
    end

    getter! current_asset_category : ::PlaceOS::Model::AssetCategory

    # 404 unless the category belongs to the caller's authority. Legacy categories with no authority
    # stay reachable (they're adopted on update). Applies to admin and support users too.
    @[AC::Route::Filter(:before_action, only: [:show])]
    private def confirm_authority
      owner = current_asset_category.authority_id
      return if owner.nil? || owner == current_authority.as(::PlaceOS::Model::Authority).id
      raise Error::NotFound.new("asset category #{current_asset_category.id} not found")
    end

    ###############################################################################################

    # List asset categories.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "true returns only hidden categories, false only non-hidden categories; omit to return all categories",
        example: "true")]
      hidden : Bool? = nil,
    ) : Array(::PlaceOS::Model::AssetCategory)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::AssetCategory.all
      query = query.where("authority_id IS NULL OR authority_id = ?", current_authority.as(::PlaceOS::Model::Authority).id)

      # NOTE:: the Elasticsearch implementation silently skipped this filter
      # when `hidden=false` (Crystal falsy), contradicting the documented
      # behaviour — both values now filter as described
      unless hidden.nil?
        query = query.where(hidden: hidden)
      end

      paginate_search(query, ::PlaceOS::Model::AssetCategory.table_name)
    end

    # Get a single asset category.
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::AssetCategory
      current_asset_category
    end

    # Update an asset category with the fields in the request body and return the saved category.
    @[AC::Route::PATCH("/:id", body: :asset_category)]
    @[AC::Route::PUT("/:id", body: :asset_category)]
    def update(asset_category : ::PlaceOS::Model::AssetCategory) : ::PlaceOS::Model::AssetCategory
      current = current_asset_category
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id

      # A category that already belongs to another authority may not be edited.
      # Legacy records with no authority get adopted by the current authority.
      if (existing = current.authority_id) && existing != authority_id
        raise Error::Forbidden.new("asset category belongs to another authority")
      end

      current.assign_attributes(asset_category)
      current.authority_id = authority_id
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # Create an asset category.
    @[AC::Route::POST("/", body: :asset_category, status_code: HTTP::Status::CREATED)]
    def create(asset_category : ::PlaceOS::Model::AssetCategory) : ::PlaceOS::Model::AssetCategory
      asset_category.authority_id = current_authority.as(::PlaceOS::Model::Authority).id
      raise Error::ModelValidation.new(asset_category.errors) unless asset_category.save
      asset_category
    end

    # Delete an asset category.
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      # A category owned by another authority may not be removed (same guard
      # as update; legacy records with no authority remain removable).
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id
      if (existing = current_asset_category.authority_id) && existing != authority_id
        raise Error::Forbidden.new("asset category belongs to another authority")
      end

      current_asset_category.destroy
    end
  end
end
