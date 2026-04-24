require "placeos-models/group"
require "placeos-models/group/application"
require "placeos-models/group/user"
require "placeos-models/group/zone"
require "placeos-models/permissions"

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
    # user has Manage on — via any application that group is a member of.
    # Enforces the "can only delegate what you have" rule for GroupZone
    # creation.
    def user_can_delegate_zone?(user : ::PlaceOS::Model::User, zone_id : String) : Bool
      managed_ids = manageable_group_ids(user)
      return false if managed_ids.empty?

      # Applications those managed groups participate in
      app_ids = [] of UUID
      ::PlaceOS::Model::GroupApplicationMembership.where(group_id: managed_ids).each do |m|
        app_ids << m.application_id unless app_ids.includes?(m.application_id)
      end
      return false if app_ids.empty?

      user_id = user.id.as(String)
      ::PlaceOS::Model::GroupApplication.where(id: app_ids).each do |app|
        return true if app.zone_accessible?(user_id, zone_id)
      end
      false
    end

    def ensure_zone_delegatable!(user : ::PlaceOS::Model::User, zone_id : String)
      raise Error::Forbidden.new("zone not reachable from any of your manageable groups") unless user_can_delegate_zone?(user, zone_id)
    end
  end
end
