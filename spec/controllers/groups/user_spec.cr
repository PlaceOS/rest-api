require "../../helper"

module PlaceOS::Api
  describe Groups::Users do
    base = Groups::Users.base_route

    ::Spec.before_each { clear_group_tables }

    it "manager can add and remove a user on their group" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      manager, manager_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: manager, group: group, permissions: Model::Permissions::Manage).save!

      other = Model::Generator.user(authority: authority).save!
      payload = {
        user_id:     other.id,
        group_id:    group.id,
        permissions: Model::Permissions::Read.to_i,
      }.to_json

      create = client.post(base, body: payload, headers: manager_headers)
      create.status_code.should eq 201

      delete_path = File.join(base, other.id.to_s, group.id.to_s)
      delete = client.delete(delete_path, headers: manager_headers)
      delete.success?.should be_true
    end

    it "non-manager rejected when managing another user's entry" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority).save!
      other = Model::Generator.user(authority: authority).save!
      payload = {user_id: other.id, group_id: group.id, permissions: 1}.to_json
      client.post(base, body: payload, headers: user_headers).status_code.should eq 403
    end

    it "user can see their own entries via user_id=me" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
      group = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

      result = client.get("#{base}?user_id=me", headers: headers)
      result.status_code.should eq 200
      rows = Array(Hash(String, JSON::Any)).from_json(result.body)
      rows.map { |r| r["user_id"].as_s }.uniq.should eq [user.id.to_s]
    end
  end
end
