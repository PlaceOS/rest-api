require "placeos-models/group"
require "placeos-models/group/zone"

require "../application"

module PlaceOS::Api
  class Groups::Zones < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/group_zones/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_group_zone(group_id : String, zone_id : String)
      Log.context.set(group_id: group_id, zone_id: zone_id)
      @current_group_zone = ::PlaceOS::Model::GroupZone.find!({UUID.new(group_id), zone_id})
    end

    getter! current_group_zone : ::PlaceOS::Model::GroupZone

    @[AC::Route::Filter(:before_action, only: [:create, :update], body: :group_zone_update)]
    def parse_group_zone(@group_zone_update : ::PlaceOS::Model::GroupZone)
    end

    getter! group_zone_update : ::PlaceOS::Model::GroupZone

    # Permission gates
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_show_permissions
      return if user_admin?
      group = ::PlaceOS::Model::Group.find!(current_group_zone.group_id)
      ensure_member!(current_user, group)
    end

    @[AC::Route::Filter(:before_action, only: [:create])]
    def check_create_permissions
      return if user_admin?
      group = ::PlaceOS::Model::Group.find!(group_zone_update.group_id)
      ensure_manage!(current_user, group)
      # "Can only delegate what you have": the zone being granted must
      # already be reachable from one of the caller's manageable groups.
      ensure_zone_delegatable!(current_user, group_zone_update.zone_id)
    end

    @[AC::Route::Filter(:before_action, only: [:update, :destroy])]
    def check_modify_permissions
      return if user_admin?
      group = ::PlaceOS::Model::Group.find!(current_group_zone.group_id)
      ensure_manage!(current_user, group)
    end

    ###############################################################################################

    # List GroupZone rows. Filterable by group_id / zone_id.
    @[AC::Route::GET("/")]
    def index(
      group_id : String? = nil,
      zone_id : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupZone)
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      authority_group_ids = ::PlaceOS::Model::Group
        .where(authority_id: authority_id)
        .to_a
        .map { |g| g.id.as(UUID) }
      return [] of ::PlaceOS::Model::GroupZone if authority_group_ids.empty?

      query = ::PlaceOS::Model::GroupZone.where(group_id: authority_group_ids)

      if group_id
        target = UUID.new(group_id)
        unless user_admin?
          group = ::PlaceOS::Model::Group.find!(target)
          ensure_member!(current_user, group)
        end
        query = query.where(group_id: target)
      else
        unless user_admin?
          viewable = viewable_group_ids(current_user)
          return [] of ::PlaceOS::Model::GroupZone if viewable.empty?
          query = query.where(group_id: viewable)
        end
      end

      query = query.where(zone_id: zone_id) if zone_id
      paginate_sql(query, type: "group_zones", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:group_id/:zone_id")]
    def show : ::PlaceOS::Model::GroupZone
      current_group_zone
    end

    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::GroupZone
      gz = group_zone_update
      gz.acting_user = current_user
      raise Error::ModelValidation.new(gz.errors) unless gz.save
      gz
    end

    @[AC::Route::PATCH("/:group_id/:zone_id")]
    @[AC::Route::PUT("/:group_id/:zone_id")]
    def update : ::PlaceOS::Model::GroupZone
      current = current_group_zone
      update = group_zone_update
      current.permissions = update.permissions
      current.deny = update.deny
      current.acting_user = current_user
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::DELETE("/:group_id/:zone_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      gz = current_group_zone
      gz.acting_user = current_user
      gz.destroy
    end
  end
end
