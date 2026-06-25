require "placeos-models/group"
require "placeos-models/group/user"
require "placeos-models/group/zone"
require "placeos-models/permissions"
require "placeos-models/control_system"
require "placeos-models/module"

module PlaceOS::Api
  # Helpers for authorising actions against the group-permissions system.
  # Include in any controller that needs to gate on a user's group
  # membership or Manage grant.
  #
  # All helpers operate on the *effective* membership of a user computed
  # via the group tree's replace semantics (closest explicit ancestor
  # GroupUser entry wins). A Manage grant on a group implicitly covers
  # that group's descendants.
  module Utils::GroupPermissions
    # Effective per-group Permissions for the user, keyed by group id.
    # Groups where the user has no transitive membership are absent.
    def group_memberships(user : ::PlaceOS::Model::User) : Hash(UUID, ::PlaceOS::Model::Permissions)
      user_id = user.id.as(String)

      # Direct GroupUser rows, scoped to the user's authority.
      direct = {} of UUID => ::PlaceOS::Model::Permissions
      sql = <<-SQL
        SELECT gu.group_id, gu.permissions
        FROM group_users gu
        INNER JOIN groups g ON g.id = gu.group_id
        WHERE gu.user_id = $1 AND g.authority_id = $2
      SQL
      args = [user_id.as(::PgORM::Value), user.authority_id.as(::PgORM::Value)]
      ::PgORM::Database.connection do |conn|
        conn.query_all(sql, args: args) do |rs|
          gid = rs.read(UUID)
          perms = rs.read(Int32)
          direct[gid] = ::PlaceOS::Model::Permissions.new(perms)
        end
      end
      return direct if direct.empty?

      # Walk up the authority's group tree so transitive memberships
      # inherit the closest explicit ancestor's perms.
      parent_of = {} of UUID => UUID
      all_ids = [] of UUID
      ::PlaceOS::Model::Group.where(authority_id: user.authority_id).each do |g|
        gid = g.id.not_nil!
        all_ids << gid
        if (parent = g.parent_id)
          parent_of[gid] = parent
        end
      end

      effective = {} of UUID => ::PlaceOS::Model::Permissions
      all_ids.each do |gid|
        current = gid
        loop do
          if (p = direct[current]?)
            effective[gid] = p
            break
          end
          next_parent = parent_of[current]?
          break if next_parent.nil?
          current = next_parent
        end
      end
      effective
    end

    # True if `user` is a member (any non-zero perm) of `group`,
    # directly or via ancestor.
    def user_is_member?(user : ::PlaceOS::Model::User, group : ::PlaceOS::Model::Group) : Bool
      gid = group.id
      return false if gid.nil?
      perms = group_memberships(user)[gid]?
      !perms.nil? && perms != ::PlaceOS::Model::Permissions::None
    end

    # True if `user` has Manage on `group` (directly or via ancestor).
    def user_has_manage?(user : ::PlaceOS::Model::User, group : ::PlaceOS::Model::Group) : Bool
      gid = group.id
      return false if gid.nil?
      perms = group_memberships(user)[gid]?
      !perms.nil? && perms.manage?
    end

    # Raises Error::Forbidden unless the user has any effective
    # permission on `group`.
    def ensure_member!(user : ::PlaceOS::Model::User, group : ::PlaceOS::Model::Group)
      raise Error::Forbidden.new unless user_is_member?(user, group)
    end

    # Raises Error::Forbidden unless the user has Manage on `group`.
    def ensure_manage!(user : ::PlaceOS::Model::User, group : ::PlaceOS::Model::Group)
      raise Error::Forbidden.new unless user_has_manage?(user, group)
    end

    # Group ids the user is any kind of member of (direct or transitive).
    # Useful for scoping index queries.
    def viewable_group_ids(user : ::PlaceOS::Model::User) : Array(UUID)
      group_memberships(user).compact_map { |gid, perms| gid if perms != ::PlaceOS::Model::Permissions::None }
    end

    # Group ids the user has Manage on (direct or transitive).
    def manageable_group_ids(user : ::PlaceOS::Model::User) : Array(UUID)
      group_memberships(user).compact_map { |gid, perms| gid if perms.manage? }
    end

    # True if `zone_id` is already reachable from at least one group the
    # user has Manage on — via any subsystem one of those groups
    # participates in. Enforces the "can only delegate what you have"
    # rule for GroupZone creation.
    def user_can_delegate_zone?(user : ::PlaceOS::Model::User, zone_id : String) : Bool
      managed_ids = manageable_group_ids(user)
      return false if managed_ids.empty?

      subsystems = Set(String).new
      ::PlaceOS::Model::Group.where(id: managed_ids).each do |g|
        g.subsystems.each { |s| subsystems << s }
      end
      return false if subsystems.empty?

      authority_id = user.authority_id.as(String)
      user_id = user.id.as(String)
      subsystems.any? do |subsystem|
        ::PlaceOS::Model::Group.zone_accessible?(authority_id, subsystem, user_id, zone_id)
      end
    end

    def ensure_zone_delegatable!(user : ::PlaceOS::Model::User, zone_id : String)
      raise Error::Forbidden.new("zone not reachable from any of your manageable groups") unless user_can_delegate_zone?(user, zone_id)
    end

    # OR of the user's effective permissions across the supplied group
    # ids. Pairs with a junction-table lookup: fetch the groups linked
    # to a resource, pass them here to get the user's effective bitmask
    # on that resource.
    #
    #   linked = ::PlaceOS::Model::GroupPlaylist
    #     .where(playlist_id: id).to_a.map(&.group_id)
    #   perms = effective_permissions_for(current_user, linked)
    def effective_permissions_for(
      user : ::PlaceOS::Model::User,
      group_ids : Array(UUID),
    ) : ::PlaceOS::Model::Permissions
      return ::PlaceOS::Model::Permissions::None if group_ids.empty?
      memberships = group_memberships(user)
      group_ids.reduce(::PlaceOS::Model::Permissions::None) do |acc, gid|
        if (perms = memberships[gid]?)
          acc | perms
        else
          acc
        end
      end
    end

    # ------------------------------------------------------------------------
    # Support-subsystem authorisation
    #
    # Shared by every controller that gates on the zone-scoped "support"
    # subsystem (systems, zones, modules, settings, metadata, assets, …).
    # The host controller must also `include Utils::Permissions` (for the
    # legacy `check_access` path); `current_authority`, `current_user`,
    # `user_support?`/`user_admin?` and `request` come from `Application`.
    # ------------------------------------------------------------------------

    SUPPORT_SUBSYSTEM = "support"

    # Permissions bit corresponding to the current HTTP verb.
    def verb_permission : ::PlaceOS::Model::Permissions
      case request.method.upcase
      when "POST"         then ::PlaceOS::Model::Permissions::Create
      when "PUT", "PATCH" then ::PlaceOS::Model::Permissions::Update
      when "DELETE"       then ::PlaceOS::Model::Permissions::Delete
      else                     ::PlaceOS::Model::Permissions::None
      end
    end

    # The authority's configured "org zone" (a soft key in `authority.config`).
    # Named with a `support_` prefix to avoid clashing with controllers that
    # define their own `org_zone_id` (e.g. `modules.cr`).
    def support_org_zone_id : String?
      current_authority.as(::PlaceOS::Model::Authority).config["org_zone"]?.try(&.as_s?)
    end

    # True if the user's effective permissions on `zones` (within any of
    # `subsystems`) include `required`, or Manage (a superset). The model
    # resolver already ANDs the user's group perms with the GroupZone
    # grants, so a non-zero result means both sides agree.
    def subsystem_grants_on_zones?(
      subsystems : Array(String),
      zones : Array(String),
      required : ::PlaceOS::Model::Permissions,
    ) : Bool
      return false if zones.empty?
      authority_id = current_user.authority_id.as(String)
      user_id = current_user.id.as(String)
      subsystems.any? do |subsystem|
        perms = ::PlaceOS::Model::Group.effective_permissions(authority_id, subsystem, user_id, zones)
        perms.manage? || (perms & required) != ::PlaceOS::Model::Permissions::None
      end
    end

    # Convenience wrapper for the "support" subsystem.
    def support_subsystem_grants?(zones : Array(String), required : ::PlaceOS::Model::Permissions) : Bool
      subsystem_grants_on_zones?([SUPPORT_SUBSYSTEM], zones, required)
    end

    # Legacy org_zone permission path (backwards compatibility): the
    # request's `zones` must include the org_zone, and `current_user.groups`
    # must satisfy `admin?` (when `admin_required`) or `can_manage?`.
    def has_legacy_access?(zones : Array(String), admin_required : Bool = false) : Bool
      org_zone = support_org_zone_id
      return false unless org_zone
      return false unless zones.includes?(org_zone)
      access = check_access(current_user.groups, zones)
      admin_required ? access.admin? : access.can_manage?
    end

    # The combined support gate. Raises `Error::Forbidden` unless one of:
    #   - the JWT role bypasses (admin when `admin_required`, else support),
    #   - the legacy org_zone path grants access, or
    #   - the "support" subsystem grants `required` on `zones`.
    def ensure_support_access!(
      zones : Array(String),
      required : ::PlaceOS::Model::Permissions = verb_permission,
      admin_required : Bool = false,
    ) : Nil
      return if admin_required ? user_admin? : user_support?
      return if has_legacy_access?(zones, admin_required)
      return if support_subsystem_grants?(zones, required)
      raise Error::Forbidden.new
    end

    # Resolve a legacy prefixed parent id to the zone ids it implies:
    #   zone-… -> the zone itself
    #   sys-…  -> the control system's zones
    #   mod-…  -> the module's zones (via its systems)
    #   driver-… / user-… / other -> [] (no zone scope => deny by default)
    def support_zones_for_parent(parent_id : String?) : Array(String)
      return [] of String unless parent_id
      case
      when parent_id.starts_with?("zone-")
        [parent_id]
      when parent_id.starts_with?("sys-")
        ::PlaceOS::Model::ControlSystem.find?(parent_id).try(&.zones) || [] of String
      when parent_id.starts_with?("mod-")
        module_zones(parent_id)
      else
        [] of String
      end
    end

    # Zones a module belongs to: the union of its logic-module system
    # (`control_system_id`) and every system that references it. Empty when
    # the module is attached to no system (=> deny / admin-or-support only).
    def module_zones(module_id : String) : Array(String)
      mod = ::PlaceOS::Model::Module.find?(module_id)
      return [] of String unless mod

      zones = [] of String
      if (sys_id = mod.control_system_id) && (sys = ::PlaceOS::Model::ControlSystem.find?(sys_id))
        zones.concat(sys.zones)
      end
      ::PlaceOS::Model::ControlSystem.by_module_id(mod.id.as(String)).each do |cs|
        zones.concat(cs.zones)
      end
      zones.uniq
    end

    # Zone ids reachable by the current user via the "support" subsystem.
    # Useful for scoping index/list queries.
    def support_accessible_zone_ids : Array(String)
      authority_id = current_user.authority_id.as(String)
      user_id = current_user.id.as(String)
      ::PlaceOS::Model::Group.accessible_zone_ids(authority_id, SUPPORT_SUBSYSTEM, user_id)
    end
  end
end
