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

      authority = current_authority.as(::PlaceOS::Model::Authority)

      if zone_id = authority.config["org_zone"]?.try(&.as_s?)
        access = check_access(current_user.groups, [zone_id])
        return if access.can_manage?
      end

      head :forbidden
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_asset_type(id : String)
      Log.context.set(asset_type_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_asset_type = ::PlaceOS::Model::AssetType.find!(id)
    end

    getter! current_asset_type : ::PlaceOS::Model::AssetType

    ###############################################################################################

    # list the asset types
    @[AC::Route::GET("/", response_type: Array(::PlaceOS::Model::AssetType))]
    def index(
      @[AC::Param::Info(description: "return assets with the provided brand name", example: "Ford")]
      brand : String? = nil,
      @[AC::Param::Info(description: "return assets with the provided model number", example: "Model 2")]
      model_number : String? = nil,
      @[AC::Param::Info(description: "return asset types in the category provided", example: "category_id-1234")]
      category_id : String? = nil,
      @[AC::Param::Info(description: "filters the asset count to the zone provided", example: "zone-1234")]
      zone_id : String? = nil
    ) : String
      conditions = [] of String
      conditions << "at.brand == '#{brand}'" if brand
      conditions << "at.model_number == '#{model_number}'" if model_number
      conditions << "at.category_id == '#{category_id}'" if category_id
      conditions << "a.zone_id = '#{zone_id}'" if zone_id

      where = conditions.empty? ? "" : "AND #{conditions.join(" AND ")}"

      sql = <<-SQL
      SELECT
          json_agg(
              jsonb_strip_nulls(
                  json_build_object(
                      'id', id,
                      'name', name,
                      'brand', CASE WHEN brand IS NOT NULL THEN brand ELSE NULL END,
                      'description', CASE WHEN description IS NOT NULL THEN description ELSE NULL END,
                      'model_number', CASE WHEN model_number IS NOT NULL THEN model_number ELSE NULL END,
                      'images', CASE WHEN images IS NOT NULL THEN images ELSE NULL END,
                      'category_id', CASE WHEN category_id IS NOT NULL THEN category_id ELSE NULL END,
                      'created_at', created_at,
                      'updated_at', updated_at,
                      'asset_count', asset_count
                  )::jsonb
              )
          ) AS result
      FROM (
          SELECT
              at.id,
              at.name,
              at.brand,
              at.description,
              at.model_number,
              at.images,
              at.category_id,
              EXTRACT(EPOCH FROM at.created_at)::bigint AS created_at,
              EXTRACT(EPOCH FROM at.updated_at)::bigint AS updated_at,
              COALESCE(COUNT(a.id), 0) AS asset_count
          FROM
              asset_type at
          LEFT JOIN
              asset a
          ON
              at.id = a.asset_type_id
          #{where}
          GROUP BY
              at.id, at.name, at.brand, at.description, at.model_number, at.images, at.category_id, at.created_at, at.updated_at
      ) subquery;
      SQL

      result = PgORM::Database.connection do |db|
        db.query_one sql, &.read(JSON::PullParser?).try &.read_raw
      end
      raise Error::NotFound.new unless result
      render json: result
    end

    # show the selected asset type
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::AssetType
      current_asset_type
    end

    # udpate asset type details
    @[AC::Route::PATCH("/:id", body: :asset_type)]
    @[AC::Route::PUT("/:id", body: :asset_type)]
    def update(asset_type : ::PlaceOS::Model::AssetType) : ::PlaceOS::Model::AssetType
      current = current_asset_type
      current.assign_attributes(asset_type)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add new asset type
    @[AC::Route::POST("/", body: :asset_type, status_code: HTTP::Status::CREATED)]
    def create(asset_type : ::PlaceOS::Model::AssetType) : ::PlaceOS::Model::AssetType
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
