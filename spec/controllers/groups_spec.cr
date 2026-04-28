require "../helper"

module PlaceOS::Api
  describe Groups do
    base = Groups.base_route

    ::Spec.before_each { clear_group_tables }

    it "sys_admin can create a root group; non-admin cannot" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      payload = Model::Generator.group(authority: authority).to_json

      # non-admin rejected
      _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)
      forbidden = client.post(base, body: payload, headers: user_headers)
      forbidden.status_code.should eq 403

      # sys_admin OK
      result = client.post(base, body: payload, headers: Spec::Authentication.headers)
      result.status_code.should eq 201
      created = Model::Group.from_trusted_json(result.body)
      Model::Group.find?(created.id.not_nil!).should_not be_nil
    end

    it "a manager can create a child group under their managed root" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      root = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: root, permissions: Model::Permissions::Manage).save!

      child_payload = Model::Generator.group(authority: authority, parent: root).to_json
      result = client.post(base, body: child_payload, headers: headers)
      result.status_code.should eq 201
    end

    it "a non-manager cannot create a child group" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      root = Model::Generator.group(authority: authority).save!
      child_payload = Model::Generator.group(authority: authority, parent: root).to_json
      result = client.post(base, body: child_payload, headers: headers)
      result.status_code.should eq 403
    end

    it "#current returns groups the user belongs to with permissions" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
      root = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: root, permissions: Model::Permissions::Read).save!

      result = client.get(File.join(base, "current"), headers: headers)
      result.status_code.should eq 200
      entries = Array(Hash(String, JSON::Any)).from_json(result.body)
      entries.map { |e| e["group"]["id"].as_s }.should contain(root.id.to_s)
      entries.first["permissions"].as_i.should eq Model::Permissions::Read.to_i
    end

    it "index supports ?q= substring search on name (sys_admin)" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      alpha = Model::Generator.group(authority: authority)
      alpha.name = "Engineering-alpha-#{Random::Secure.hex(3)}"
      alpha.save!
      beta = Model::Generator.group(authority: authority, parent: alpha)
      beta.name = "Beta-team-#{Random::Secure.hex(3)}"
      beta.save!

      result = client.get("#{base}?q=engineering", headers: Spec::Authentication.headers)
      result.status_code.should eq 200
      ids = Array(Hash(String, JSON::Any)).from_json(result.body).map { |e| e["id"].as_s }
      ids.should contain(alpha.id.to_s)
      ids.should_not contain(beta.id.to_s)
    end

    it "?include_children_count=true populates children_count per row" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      root = Model::Generator.group(authority: authority).save!
      a = Model::Generator.group(authority: authority, parent: root).save!
      b = Model::Generator.group(authority: authority, parent: root).save!
      _aa = Model::Generator.group(authority: authority, parent: a).save!

      result = client.get("#{base}?include_children_count=true", headers: Spec::Authentication.headers)
      result.status_code.should eq 200
      counts = Array(Hash(String, JSON::Any)).from_json(result.body).to_h do |row|
        {row["id"].as_s, row["children_count"].as_i}
      end

      counts[root.id.to_s].should eq 2
      counts[a.id.to_s].should eq 1
      counts[b.id.to_s].should eq 0
    end

    it "index omits children_count when the flag is absent" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      root = Model::Generator.group(authority: authority).save!
      Model::Generator.group(authority: authority, parent: root).save!

      result = client.get(base, headers: Spec::Authentication.headers)
      result.status_code.should eq 200
      rows = Array(Hash(String, JSON::Any)).from_json(result.body)
      rows.each { |r| r["children_count"]?.try(&.raw).should be_nil }
    end

    it "index scopes non-admin callers to their own memberships (direct + transitive)" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      mine = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: mine, permissions: Model::Permissions::Read).save!
      child = Model::Generator.group(authority: authority, parent: mine).save!

      # Create a sibling root (new authority) to prove cross-authority is not leaking.
      other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
      _unrelated = Model::Generator.group(authority: other_authority).save!

      result = client.get(base, headers: headers)
      result.status_code.should eq 200
      ids = Array(Hash(String, JSON::Any)).from_json(result.body).map { |e| e["id"].as_s }
      ids.sort!.should eq [mine.id.to_s, child.id.to_s].sort!
    end
  end
end
