require "placeos-models/group"
require "placeos-models/group/history"

require "../application"

module PlaceOS::Api
  class Groups::History < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/group_history/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show])]
    def find_current_history(id : String)
      Log.context.set(group_history_id: id)
      @current_history = ::PlaceOS::Model::GroupHistory.find!(UUID.new(id))
    end

    getter! current_history : ::PlaceOS::Model::GroupHistory

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_show_permissions
      return if user_admin?
      if (gid = current_history.group_id)
        group = ::PlaceOS::Model::Group.find!(gid)
        ensure_manage!(current_user, group)
      else
        # History entry without a group_id (e.g. GroupApplication create)
        # — sys_admin only.
        raise Error::Forbidden.new
      end
    end

    ###############################################################################################

    # List audit entries. sys_admin sees everything; other callers must
    # pass `group_id=` and have Manage on it. `application_id` is an
    # optional additional filter for sys_admin callers.
    @[AC::Route::GET("/")]
    def index(
      group_id : String? = nil,
      application_id : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupHistory)
      if user_admin?
        query = ::PlaceOS::Model::GroupHistory.all
        query = query.where(group_id: UUID.new(group_id)) if group_id
        query = query.where(application_id: UUID.new(application_id)) if application_id
      else
        # Non-admin must scope to a specific group they manage.
        raise Error::Forbidden.new("group_id is required") unless group_id
        target = UUID.new(group_id)
        group = ::PlaceOS::Model::Group.find!(target)
        ensure_manage!(current_user, group)
        query = ::PlaceOS::Model::GroupHistory.where(group_id: target)
        query = query.where(application_id: UUID.new(application_id)) if application_id
      end

      paginate_sql(query, type: "group_history", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::GroupHistory
      current_history
    end
  end
end
