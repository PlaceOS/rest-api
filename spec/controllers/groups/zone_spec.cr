require "../../helper"

module PlaceOS::Api
  describe Groups::Zones do
    base = Groups::Zones.base_route

    ::Spec.before_each { clear_group_tables }

    it "manager can delegate a zone they already have coverage on" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      manager, manager_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      parent_group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
      child_group = Model::Generator.group(authority: authority, parent: parent_group, subsystems: ["signage"]).save!
      Model::Generator.group_user(user: manager, group: parent_group, permissions: Model::Permissions::Manage).save!

      zone = Model::Generator.zone.save!
      Model::Generator.group_zone(group: parent_group, zone: zone, permissions: Model::Permissions::All).save!

      # Manager delegates the (already-covered) zone to the child group.
      payload = {
        group_id:    child_group.id,
        zone_id:     zone.id,
        permissions: Model::Permissions::Read.to_i,
      }.to_json
      result = client.post(base, body: payload, headers: manager_headers)
      result.status_code.should eq 201
    end

    it "index hydrates each row with the embedded group and zone" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

      zone = Model::Generator.zone.save!
      Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

      result = client.get("#{base}?group_id=#{group.id}", headers: headers)
      result.status_code.should eq 200
      rows = Array(Hash(String, JSON::Any)).from_json(result.body)
      rows.size.should eq 1
      rows[0]["group"]["id"].as_s.should eq group.id.to_s
      rows[0]["zone"]["id"].as_s.should eq zone.id.to_s
    end

    it "manager cannot delegate a zone they have no coverage on" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      manager, manager_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      parent_group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
      child_group = Model::Generator.group(authority: authority, parent: parent_group, subsystems: ["signage"]).save!
      Model::Generator.group_user(user: manager, group: parent_group, permissions: Model::Permissions::Manage).save!

      # Manager has no grant for this zone at all.
      unreachable = Model::Generator.zone.save!
      payload = {
        group_id:    child_group.id,
        zone_id:     unreachable.id,
        permissions: Model::Permissions::Read.to_i,
      }.to_json
      result = client.post(base, body: payload, headers: manager_headers)
      result.status_code.should eq 403
    end
  end
end
