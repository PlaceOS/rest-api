require "../../helper"

module PlaceOS::Api
  describe Groups::Invitations do
    base = Groups::Invitations.base_route

    ::Spec.before_each { clear_group_tables }

    it "manager can create and destroy invitations; response includes plaintext_secret once" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      manager, manager_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: manager, group: group, permissions: Model::Permissions::Manage).save!

      payload = {
        group_id:    group.id,
        email:       "invited-#{Random::Secure.hex(4)}@example.com",
        permissions: Model::Permissions::Read.to_i,
      }.to_json
      create = client.post(base, body: payload, headers: manager_headers)
      create.status_code.should eq 201

      body = JSON.parse(create.body)
      body["plaintext_secret"].as_s.size.should be > 10
      id = body["invitation"]["id"].as_s

      delete = client.delete(File.join(base, id), headers: manager_headers)
      delete.success?.should be_true
    end

    it "rejects invitation creation without Manage" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority).save!
      payload = {
        group_id:    group.id,
        email:       "invited-#{Random::Secure.hex(4)}@example.com",
        permissions: 1,
      }.to_json
      client.post(base, body: payload, headers: user_headers).status_code.should eq 403
    end

    it "user can accept an invitation they're eligible for" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      group = Model::Generator.group(authority: authority).save!
      invitation = Model::GroupInvitation.build_with_secret(
        group: group,
        email: user.email.to_s,
        permissions: Model::Permissions::Read,
      )
      invitation.save!

      result = client.post(File.join(base, invitation.id.to_s, "accept"), headers: headers)
      result.status_code.should eq 200
      gu = Model::GroupUser.from_trusted_json(result.body)
      gu.user_id.should eq user.id
      gu.group_id.should eq group.id
      Model::GroupInvitation.find?(invitation.id.not_nil!).should be_nil
    end
  end
end
