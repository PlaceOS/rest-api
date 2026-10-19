require "../../helper"

module PlaceOS::Api
  describe Groups::History do
    base = Groups::History.base_route

    it "sys_admin can list all history; non-admin must scope to a managed group" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      admin = Spec::Authentication.user(sys_admin: true)
      manager, manager_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority)
      group.history_metadata = Model::History::Metadata.new.with_user(admin)
      group.save!

      Model::Generator.group_user(user: manager, group: group, permissions: Model::Permissions::Manage).save!

      # non-admin with no group_id → 403
      client.get(base, headers: manager_headers).status_code.should eq 403

      # non-admin with group_id they manage → 200
      scoped = client.get("#{base}?group_id=#{group.id}", headers: manager_headers)
      scoped.status_code.should eq 200
      entries = Array(Model::History).from_json(scoped.body)
      entries.map(&.resource_type).should eq ["group_users", "groups"]
      entries.all?(&.correlation_id.==(group.id.to_s)).should be_true
      entries.last.user_id.should eq admin.id

      # entries of the group can be shown by its manager
      shown = client.get("#{base}#{entries.last.id}", headers: manager_headers)
      shown.status_code.should eq 200

      # entries of other resources are not group history
      other = Model::Generator.zone.save!
      zone_entry = other.change_history.to_a.first
      client.get("#{base}#{zone_entry.id}", headers: Spec::Authentication.headers).status_code.should eq 404

      # sys_admin unfiltered → 200
      client.get(base, headers: Spec::Authentication.headers).status_code.should eq 200
    end
  end
end
