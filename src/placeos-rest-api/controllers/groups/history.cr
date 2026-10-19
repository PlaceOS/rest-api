require "placeos-models/group"
require "placeos-models/history"

require "../application"

module PlaceOS::Api
  # Audit history of changes to groups and their memberships
  class Groups::History < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/group_history/"

    # Change history of these tables is correlated to the group
    RESOURCE_TYPES = %w[groups group_users group_zones group_invitations]

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show])]
    def find_current_history(id : UUID)
      Log.context.set(group_history_id: id.to_s)
      history = ::PlaceOS::Model::History.find!(id)
      raise Error::NotFound.new("not a group history entry") unless history.resource_type.in?(RESOURCE_TYPES)
      @current_history = history
    end

    getter! current_history : ::PlaceOS::Model::History

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_show_permissions
      return if user_admin?
      if gid = current_history.correlation_id
        group = ::PlaceOS::Model::Group.find!(UUID.new(gid))
        ensure_manage!(current_user, group)
      else
        # History entry without a group — sys_admin only.
        raise Error::Forbidden.new
      end
    end

    ###############################################################################################

    # List audit entries, newest first. sys_admin sees everything; other
    # callers must pass `group_id=` and have Manage on it.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "only return changes to this group and its memberships", example: "0192d1c8-2f0e-7cc1-9d2a-6f1c7e1b3a51")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "the maximum number of results to return", example: "100")]
      limit : Int32 = 100,
      @[AC::Param::Info(description: "the starting offset of the result set, used to implement pagination")]
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::History)
      unless user_admin?
        # Non-admin must scope to a specific group they manage.
        raise Error::Forbidden.new("group_id is required") unless group_id
        group = ::PlaceOS::Model::Group.find!(group_id)
        ensure_manage!(current_user, group)
      end

      query = if group_id
                ::PlaceOS::Model::History.correlated(group_id.to_s)
              else
                ::PlaceOS::Model::History
                  .where(resource_type: RESOURCE_TYPES)
                  .order(created_at: :desc, id: :desc)
              end

      paginate_sql(query, type: "group_history", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::History
      current_history
    end
  end
end
