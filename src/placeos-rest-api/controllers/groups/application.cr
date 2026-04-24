require "placeos-models/group/application"
require "placeos-models/permissions"

require "../application"

module PlaceOS::Api
  class Groups::Applications < Application
    base "/api/engine/v2/group_applications/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :effective_permissions, :accessible_zones]
    before_action :can_write, only: [:create, :update, :destroy]

    # Only sys_admin can create, update, or destroy.
    before_action :check_admin, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_application(id : String)
      Log.context.set(group_application_id: id)
      @current_application = ::PlaceOS::Model::GroupApplication.find!(UUID.new(id))
    end

    getter! current_application : ::PlaceOS::Model::GroupApplication

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :application_update)]
    def parse_update_application(@application_update : ::PlaceOS::Model::GroupApplication)
    end

    getter! application_update : ::PlaceOS::Model::GroupApplication

    ###############################################################################################

    # List applications for the current authority. Any authenticated
    # user may list — codes are labels, not secrets. Pass `q` for a
    # case-insensitive substring search on `name`.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "case-insensitive substring search on name (SQL ILIKE)")]
      q : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupApplication)
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      query = ::PlaceOS::Model::GroupApplication.where(authority_id: authority_id)

      if (term = q) && !term.empty?
        query = query.where("name ILIKE ?", "%#{term}%")
      end

      paginate_sql(query, type: "group_applications", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::GroupApplication
      current_application
    end

    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::GroupApplication
      app = application_update
      app.authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      app.acting_user = current_user
      raise Error::ModelValidation.new(app.errors) unless app.save
      app
    end

    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::GroupApplication
      current = current_application
      current.assign_attributes(application_update)
      current.acting_user = current_user
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      app = current_application
      app.acting_user = current_user
      app.destroy
    end

    # Permission query helpers
    ###############################################################################################

    struct EffectivePermissionsResponse
      include JSON::Serializable

      getter application_id : UUID
      getter user_id : String
      getter permissions : Int32
      getter zone_ids : Array(String)

      def initialize(@application_id, @user_id, @permissions, @zone_ids)
      end
    end

    # Effective permissions for the *current user* on the given zone(s)
    # within this application. Either `zone_id=...` (single) or
    # `zone_ids=a,b,c` (comma-separated batch).
    @[AC::Route::GET("/:id/effective_permissions", converters: {zone_ids: ConvertStringArray})]
    def effective_permissions(
      @[AC::Param::Info(description: "single zone id (use either this or zone_ids)")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "comma-separated list of zone ids")]
      zone_ids : Array(String)? = nil,
    ) : EffectivePermissionsResponse
      user_id = current_user.id.as(String)
      app = current_application
      app_id = app.id.as(UUID)

      if zone_ids && !zone_ids.empty?
        perms = app.effective_permissions(user_id, zone_ids)
        EffectivePermissionsResponse.new(app_id, user_id, perms.to_i, zone_ids)
      elsif zone_id
        perms = app.effective_permissions(user_id, zone_id)
        EffectivePermissionsResponse.new(app_id, user_id, perms.to_i, [zone_id])
      else
        raise AC::Route::Param::MissingError.new("either `zone_id` or `zone_ids` must be supplied", "zone_id", "String")
      end
    end

    struct AccessibleZonesResponse
      include JSON::Serializable

      getter application_id : UUID
      getter user_id : String
      getter zone_ids : Array(String)

      def initialize(@application_id, @user_id, @zone_ids)
      end
    end

    # Every zone id the current user has any non-zero permission on
    # within this application (direct + transitive, minus denies).
    @[AC::Route::GET("/:id/accessible_zones")]
    def accessible_zones : AccessibleZonesResponse
      user_id = current_user.id.as(String)
      app = current_application
      AccessibleZonesResponse.new(
        app.id.as(UUID),
        user_id,
        app.accessible_zone_ids(user_id),
      )
    end
  end
end
