require "./application"

module PlaceOS::Api
  class AssetCategories < Application
    include Utils::Permissions

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

    ###############################################################################################

    # list the asset categories
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "Filter categories by hidden status. `true` returns only hidden categories, `false` returns only non-hidden categories, and `nil` returns all categories.",
        example: "true")]
      hidden : Bool? = nil,
    ) : Array(::PlaceOS::Model::AssetCategory)
      elastic = ::PlaceOS::Model::AssetCategory.elastic
      query = elastic.query(search_params)

      if value = hidden
        query.must({
          "hidden" => [value],
        })
      end
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # show the selected asset category
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::AssetCategory
      current_asset_category
    end

    # udpate asset category details
    @[AC::Route::PATCH("/:id", body: :asset_category)]
    @[AC::Route::PUT("/:id", body: :asset_category)]
    def update(asset_category : ::PlaceOS::Model::AssetCategory) : ::PlaceOS::Model::AssetCategory
      current = current_asset_category
      current.assign_attributes(asset_category)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset category
    @[AC::Route::POST("/", body: :asset_category, status_code: HTTP::Status::CREATED)]
    def create(asset_category : ::PlaceOS::Model::AssetCategory) : ::PlaceOS::Model::AssetCategory
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
