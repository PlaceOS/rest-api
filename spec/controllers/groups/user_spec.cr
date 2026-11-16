require "../../helper"

module PlaceOS::Api
  describe Groups::Users do
    base = Groups::Users.base_route

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
      rows.map(&.["user_id"].as_s).uniq!.should eq [user.id.to_s]
    end

    it "index hydrates each row with the embedded group and user" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
      group = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

      result = client.get("#{base}?user_id=me", headers: headers)
      result.status_code.should eq 200
      rows = Array(Hash(String, JSON::Any)).from_json(result.body)
      rows.size.should eq 1
      rows[0]["group"]["id"].as_s.should eq group.id.to_s
      rows[0]["user"]["id"].as_s.should eq user.id.to_s
    end

    describe "sensitive fields" do
      secret_fields = %w[password password_digest access_token refresh_token expires_at expires]
      admin_only_fields = %w[sys_admin support misc login_name card_number ui_theme]

      {
        {"group manager", false},
        {"sys_admin", true},
      }.each do |role, sys_admin|
        it "index never embeds a member's password digest or SSO tokens for a #{role}" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          caller, headers = Spec::Authentication.authentication(sys_admin: sys_admin, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: caller, group: group, permissions: Model::Permissions::Manage).save!

          tag = Random::Secure.hex(6)
          member = Model::Generator.user(authority: authority)
          member.password = "s3cr3t-p@ssw0rd"
          member.access_token = "ms-access-token-#{tag}"
          member.refresh_token = "ms-refresh-token-#{tag}"
          member.expires_at = 1.hour.from_now.to_unix
          member.expires = true
          member.misc = "admin notes"
          member.card_number = "card-#{tag}"
          member.save!
          member.password_digest.should_not be_nil
          Model::Generator.group_user(user: member, group: group, permissions: Model::Permissions::Read).save!

          result = client.get("#{base}?group_id=#{group.id}", headers: headers)
          result.status_code.should eq 200

          rows = Array(Hash(String, JSON::Any)).from_json(result.body)
          member_row = rows.find! { |row| row["user_id"].as_s == member.id }
          embedded = member_row["user"].as_h
          embedded["id"].as_s.should eq member.id
          (embedded.keys & secret_fields).should be_empty
          # Embedded users are always the public view, even for admins
          (embedded.keys & admin_only_fields).should be_empty

          result.body.should_not contain(member.password_digest.as(String))
          result.body.should_not contain(member.access_token.as(String))
          result.body.should_not contain(member.refresh_token.as(String))
        end
      end
    end
  end
end
