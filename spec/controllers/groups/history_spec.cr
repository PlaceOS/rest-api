require "../../helper"

module PlaceOS::Api
  describe Groups::History do
    base = Groups::History.base_route

    ::Spec.before_each { clear_group_tables }

    it "sys_admin can list all history; non-admin must scope to a managed group" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      admin = Spec::Authentication.user(sys_admin: true)
      manager, manager_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority)
      group.acting_user = admin
      group.save!

      Model::Generator.group_user(user: manager, group: group, permissions: Model::Permissions::Manage).save!

      # non-admin with no group_id → 403
      client.get(base, headers: manager_headers).status_code.should eq 403

      # non-admin with group_id they manage → 200
      scoped = client.get("#{base}?group_id=#{group.id}", headers: manager_headers)
      scoped.status_code.should eq 200

      # sys_admin unfiltered → 200
      client.get(base, headers: Spec::Authentication.headers).status_code.should eq 200
    end
  end
end
