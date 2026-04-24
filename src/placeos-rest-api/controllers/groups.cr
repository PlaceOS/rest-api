require "placeos-models/group"
require "placeos-models/permissions"

require "./application"

module PlaceOS::Api
  class Groups < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/groups/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :current]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :current])]
    def find_current_group(id : String)
      Log.context.set(group_id: id)
      @current_group = ::PlaceOS::Model::Group.find!(UUID.new(id))
    end

    getter! current_group : ::PlaceOS::Model::Group

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :group_update)]
    def parse_update_group(@group_update : ::PlaceOS::Model::Group)
    end

    getter! group_update : ::PlaceOS::Model::Group

    # Permission gates
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_show_permissions
      return if user_admin?
      ensure_member!(current_user, current_group)
    end

    @[AC::Route::Filter(:before_action, only: [:create])]
    def check_create_permissions
      return if user_admin?
      # Root groups (parent_id nil) can only be created by sys_admin.
      parent_id = group_update.parent_id
      raise Error::Forbidden.new("only sys_admin may create a root group") if parent_id.nil?
      parent = ::PlaceOS::Model::Group.find!(parent_id)
      ensure_manage!(current_user, parent)
    end

    @[AC::Route::Filter(:before_action, only: [:update])]
    def check_update_permissions
      return if user_admin?
      ensure_manage!(current_user, current_group)
      # Block reparenting unless manager also has Manage on the new parent.
      new_parent_id = group_update.parent_id
      if new_parent_id && new_parent_id != current_group.parent_id
        new_parent = ::PlaceOS::Model::Group.find!(new_parent_id)
        ensure_manage!(current_user, new_parent)
      end
    end

    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_destroy_permissions
      return if user_admin?
      # Can't delete a root group unless sys_admin.
      parent_id = current_group.parent_id
      raise Error::Forbidden.new("only sys_admin may delete a root group") if parent_id.nil?
      parent = ::PlaceOS::Model::Group.find!(parent_id)
      ensure_manage!(current_user, parent)
    end

    ###############################################################################################

    # List groups. sys_admin sees all within the current authority; other
    # users see only groups they're a member of (direct or transitive).
    # Optionally filter by `parent_id` for tree queries (pass the
    # literal string `root` for root-level groups). Pass `q` for a
    # case-insensitive substring search on `name`.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter by parent group id; pass 'root' for root-level groups")]
      parent_id : String? = nil,
      @[AC::Param::Info(description: "case-insensitive substring search on name (SQL ILIKE)")]
      q : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::Group)
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      query = ::PlaceOS::Model::Group.where(authority_id: authority_id)

      unless user_admin?
        ids = viewable_group_ids(current_user)
        return [] of ::PlaceOS::Model::Group if ids.empty?
        query = query.where(id: ids)
      end

      if parent_id
        if parent_id == "root"
          query = query.where(parent_id: nil)
        else
          query = query.where(parent_id: UUID.new(parent_id))
        end
      end

      if (term = q) && !term.empty?
        query = query.where("name ILIKE ?", "%#{term}%")
      end

      paginate_sql(query, type: "groups", limit: limit, offset: offset)
    end

    # Show group details. Visible if sys_admin or a member.
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Group
      current_group
    end

    # Update the group (name / description / parent).
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::Group
      update = group_update
      current = current_group
      current.assign_attributes(update)
      current.acting_user = current_user
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # Create a new group. A root group (parent_id nil) requires
    # sys_admin; a child group requires Manage on the parent.
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::Group
      group = group_update
      # Force the authority to the caller's — no cross-authority moves.
      group.authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      group.acting_user = current_user
      raise Error::ModelValidation.new(group.errors) unless group.save
      group
    end

    # Destroy a group (cascades children and junctions via FK).
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      group = current_group
      group.acting_user = current_user
      group.destroy
    end

    # Groups the current user is a member of (direct or via ancestor),
    # within the current authority. Lightweight — returns the group
    # rows plus the user's effective permission bitmask per group.
    struct CurrentGroup
      include JSON::Serializable

      getter group : ::PlaceOS::Model::Group
      getter permissions : Int32

      def initialize(@group, @permissions)
      end
    end

    @[AC::Route::GET("/current")]
    def current : Array(CurrentGroup)
      memberships = group_memberships(current_user)
      return [] of CurrentGroup if memberships.empty?

      groups = ::PlaceOS::Model::Group.where(id: memberships.keys).to_a
      groups.compact_map do |g|
        gid = g.id
        next if gid.nil?
        perms = memberships[gid]? || ::PlaceOS::Model::Permissions::None
        next if perms == ::PlaceOS::Model::Permissions::None
        CurrentGroup.new(g, perms.to_i)
      end
    end
  end
end

require "./groups/*"
