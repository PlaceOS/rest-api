require "./application"

module PlaceOS::Api
  class AssetTypes < Application
    include Utils::Permissions

    base "/api/engine/v2/asset_types/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    @[AC::Route::Filter(:before_action, only: [:create, :update, :destroy])]
    private def confirm_access
      return if user_support?

      authority = current_authority.as(Model::Authority)

      if zone_id = authority.config["org_zone"]?.try(&.as_s?)
        access = check_access(current_user.groups, [zone_id])
        return if access.manage? || access.admin?
      end

      head :forbidden
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_type(id : String)
      Log.context.set(asset_type_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset_type = Model::AssetType.find!(id)
    end

    getter! current_asset_type : Model::AssetType

    ###############################################################################################

    def self.apply_counts(results : Array(Model::AssetType), zone_id : String? = nil) : Hash(String, Int64)
      counts = {} of String => Int64
      return counts if results.empty?
      zone_id = zone_id.presence

      sql_query = %{
        SELECT asset_type_id, COUNT(*) as child_count
        FROM asset
        WHERE asset_type_id IN ('#{results.map(&.id).join("','")}') #{zone_id ? "AND zone_id = '#{zone_id.gsub(/['";]/, "")}'" : ""}
        GROUP BY asset_type_id
      }

      PgORM::Database.connection do |db|
        db.query_all(
          sql_query,
          as: {String, Int64}
        ).each { |(id, count)| counts[id] = count }
      end

      results.each { |type| type.asset_count = counts[type.id]? || 0_i64 }
      counts
    end

    # list the asset types
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return assets with the provided brand name", example: "Ford")]
      brand : String? = nil,
      @[AC::Param::Info(description: "return assets with the provided model number", example: "Model 2")]
      model_number : String? = nil,
      @[AC::Param::Info(description: "return asset types in the category provided", example: "category_id-1234")]
      category_id : String? = nil,
      @[AC::Param::Info(description: "filters the asset count to the zone provided", example: "zone-1234")]
      zone_id : String? = nil
    ) : Array(Model::AssetType)
      elastic = Model::AssetType.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      results = paginate_results(elastic, query)

      if brand
        query.must({
          "brand" => [brand],
        })
      end

      if model_number
        query.must({
          "model_number" => [model_number],
        })
      end

      if category_id
        query.must({
          "category_id" => [category_id],
        })
      end

      # optimise the rendering of the counts, avoid the N + 1 problem
      self.class.apply_counts(results, zone_id)
      results
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
