require "json"

module PlaceOS::Api::Utils::Permissions
  enum Permission
    None
    Manage
    Admin
    Deny

    def can_manage?
      manage? || admin?
    end
  end

  class PermissionsMeta
    include JSON::Serializable

    getter deny : Array(String)?
    getter manage : Array(String)?
    getter admin : Array(String)?

    # Returns {permission_found, access_level}
    def has_access?(groups : Array(String)) : Tuple(Bool, Permission)
      groups.map! &.downcase

      case
      when (is_deny = deny.try(&.map!(&.downcase))) && !(is_deny & groups).empty?
        {false, Permission::Deny}
      when (can_manage = manage.try(&.map!(&.downcase))) && !(can_manage & groups).empty?
        {true, Permission::Manage}
      when (can_admin = admin.try(&.map!(&.downcase))) && !(can_admin & groups).empty?
        {true, Permission::Admin}
      else
        {true, Permission::None}
      end
    end
  end

  # https://docs.google.com/document/d/1OaZljpjLVueFitmFWx8xy8BT8rA2lITyPsIvSYyNNW8/edit#
  # See the section on user-permissions
  def check_access(groups : Array(String), zones : Array(String))
    metadatas = Model::Metadata.where(
      parent_id: zones,
      name: "permissions"
    ).to_a.to_h { |meta| {meta.parent_id, meta} }

    access = Permission::None
    zones.each do |zone_id|
      if metadata = metadatas[zone_id]?.try(&.details)
        continue, permission = PermissionsMeta.from_json(metadata.to_json).has_access?(groups)
        access = permission unless permission.none?
        break unless continue
      end
    end
    access
  end
end
