require "placeos-models/group"
require "placeos-models/group/user"

require "../application"

module PlaceOS::Api
  class Groups::Users < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/group_users/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_group_user(user_id : String, group_id : String)
      Log.context.set(user_id: user_id, group_id: group_id)
      @current_group_user = ::PlaceOS::Model::GroupUser.find!({user_id, UUID.new(group_id)})
    end

    getter! current_group_user : ::PlaceOS::Model::GroupUser

    @[AC::Route::Filter(:before_action, only: [:create, :update], body: :group_user_update)]
    def parse_group_user(@group_user_update : ::PlaceOS::Model::GroupUser)
    end

    getter! group_user_update : ::PlaceOS::Model::GroupUser

    # Permission gates
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_show_permissions
      return if user_admin?
      gu = current_group_user
      # Own entry always visible.
      return if gu.user_id == current_user.id
      group = ::PlaceOS::Model::Group.find!(gu.group_id)
      ensure_manage!(current_user, group)
    end

    @[AC::Route::Filter(:before_action, only: [:create])]
    def check_create_permissions
      return if user_admin?
      group = ::PlaceOS::Model::Group.find!(group_user_update.group_id)
      ensure_manage!(current_user, group)
    end

    @[AC::Route::Filter(:before_action, only: [:update, :destroy])]
    def check_modify_permissions
      return if user_admin?
      group = ::PlaceOS::Model::Group.find!(current_group_user.group_id)
      ensure_manage!(current_user, group)
    end

    ###############################################################################################

    # GroupUser rows. Optional `group_id` scopes to one group;
    # `user_id=me` returns the current user's own rows. Non-admin
    # callers without Manage on the specified group see only their own.
    @[AC::Route::GET("/")]
    def index(
      group_id : String? = nil,
      user_id : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupUser)
      # Constrain to the caller's authority.
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      authority_group_ids = ::PlaceOS::Model::Group
        .where(authority_id: authority_id)
        .to_a
        .map { |g| g.id.as(UUID) }
      return [] of ::PlaceOS::Model::GroupUser if authority_group_ids.empty?

      query = ::PlaceOS::Model::GroupUser.where(group_id: authority_group_ids)

      if user_id == "me"
        query = query.where(user_id: current_user.id.as(String))
      elsif user_id
        # Only sys_admin can look up other users.
        raise Error::Forbidden.new unless user_admin? || user_id == current_user.id
        query = query.where(user_id: user_id)
      end

      if group_id
        target = UUID.new(group_id)
        unless user_admin?
          group = ::PlaceOS::Model::Group.find!(target)
          # Non-Manager: allow only if asking about their own entries.
          unless user_has_manage?(current_user, group)
            raise Error::Forbidden.new unless user_id == "me" || user_id == current_user.id
          end
        end
        query = query.where(group_id: target)
      elsif !user_admin?
        # No group filter + non-admin: restrict to groups they manage OR their own rows.
        managed = manageable_group_ids(current_user)
        own_user_id = current_user.id.as(String)
        if managed.empty?
          query = query.where(user_id: own_user_id)
        else
          # (group_id IN managed) OR user_id = self
          ids_list = managed.map(&.to_s).join(",") { |s| "'#{s}'" }
          query = query.where(
            "(group_id::text = ANY(ARRAY[#{ids_list}]) OR user_id = ?)", own_user_id,
          )
        end
      end

      paginate_sql(query, type: "group_users", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:user_id/:group_id")]
    def show : ::PlaceOS::Model::GroupUser
      current_group_user
    end

    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::GroupUser
      gu = group_user_update
      gu.acting_user = current_user
      raise Error::ModelValidation.new(gu.errors) unless gu.save
      gu
    end

    @[AC::Route::PATCH("/:user_id/:group_id")]
    @[AC::Route::PUT("/:user_id/:group_id")]
    def update : ::PlaceOS::Model::GroupUser
      current = current_group_user
      # Only permissions are mutable on this junction; composite PK is immutable.
      new_perms = group_user_update.permissions
      current.permissions = new_perms
      current.acting_user = current_user
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::DELETE("/:user_id/:group_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      gu = current_group_user
      gu.acting_user = current_user
      gu.destroy
    end
  end
end
