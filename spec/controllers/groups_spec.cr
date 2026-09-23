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
      entries.map(&.["group"].["id"].as_s).should contain(root.id.to_s)
      entries.first["permissions"].as_i.should eq Model::Permissions::Read.to_i
    end

    it "#current?subsystem= filters to groups participating in that subsystem" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      # Two child groups under the same root; user has Read on the
      # root (transitive membership in both children). Only one
      # child participates in the "signage" subsystem.
      root = Model::Generator.group(authority: authority).save!
      Model::Generator.group_user(user: user, group: root, permissions: Model::Permissions::Read).save!
      signage_group = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!
      events_group = Model::Generator.group(authority: authority, parent: root, subsystems: ["events"]).save!

      result = client.get(File.join(base, "current?subsystem=signage"), headers: headers)
      result.status_code.should eq 200
      ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["group"].["id"].as_s)
      ids.should contain(signage_group.id.to_s)
      ids.should_not contain(events_group.id.to_s)
      ids.should_not contain(root.id.to_s)
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
      ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
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
      ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
      ids.sort!.should eq [mine.id.to_s, child.id.to_s].sort!
    end

    describe "features" do
      feature_json = ->(json : String) { Hash(String, Hash(String, JSON::Any)).from_json(json) }

      it "returns the effective features merged down from the root" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root = Model::Generator.group(authority: authority, subsystems: ["signage", "events"],
          features: feature_json.call(%({"signage": {"ai": true, "templates": true}, "events": {"catering": true}}))).save!
        child = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"],
          features: feature_json.call(%({"signage": {"ai": false}}))).save!
        Model::Generator.group_user(user: user, group: child, permissions: Model::Permissions::Read).save!

        result = client.get(File.join(base, child.id.to_s, "features"), headers: headers)
        result.status_code.should eq 200
        body = Hash(String, Hash(String, JSON::Any)).from_json(result.body)
        body["signage"]["ai"].as_bool.should be_false
        body["signage"]["templates"].as_bool.should be_true
        body["events"]["catering"].as_bool.should be_true
      end

      it "?subsystem= returns only that subsystem" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        root = Model::Generator.group(authority: authority, subsystems: ["signage", "events"],
          features: feature_json.call(%({"signage": {"ai": true}, "events": {"catering": true}}))).save!

        result = client.get(File.join(base, root.id.to_s, "features?subsystem=signage"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        body = Hash(String, Hash(String, JSON::Any)).from_json(result.body)
        body.keys.should eq ["signage"]
        body["signage"]["ai"].as_bool.should be_true

        unknown = client.get(File.join(base, root.id.to_s, "features?subsystem=parking"), headers: Spec::Authentication.headers)
        Hash(String, Hash(String, JSON::Any)).from_json(unknown.body).should eq({"parking" => {} of String => JSON::Any})
      end

      it "is forbidden to non-members" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        root = Model::Generator.group(authority: authority).save!

        result = client.get(File.join(base, root.id.to_s, "features"), headers: headers)
        result.status_code.should eq 403
      end

      it "a manager of only the group itself can't change its features, but can edit other fields" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        root = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        child = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"],
          features: feature_json.call(%({"signage": {"ai": false}}))).save!
        Model::Generator.group_user(user: user, group: child, permissions: Model::Permissions::Manage).save!

        path = File.join(base, child.id.to_s)
        forbidden = client.patch(path, body: {features: {signage: {ai: true}}}.to_json, headers: headers)
        forbidden.status_code.should eq 403

        # Omitting features (or resending them unchanged) is fine and preserves them
        renamed = client.patch(path, body: {name: "renamed"}.to_json, headers: headers)
        renamed.status_code.should eq 200
        unchanged = client.patch(path, body: {features: {signage: {ai: false}}}.to_json, headers: headers)
        unchanged.status_code.should eq 200

        reloaded = Model::Group.find!(child.id.not_nil!)
        reloaded.name.should eq "renamed"
        reloaded.features["signage"]["ai"].as_bool.should be_false
      end

      it "a manager of the parent can change a child's features" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        root = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        child = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: root, permissions: Model::Permissions::Manage).save!

        result = client.patch(File.join(base, child.id.to_s), body: {features: {signage: {ai: true}}}.to_json, headers: headers)
        result.status_code.should eq 200
        Model::Group.find!(child.id.not_nil!).features["signage"]["ai"].as_bool.should be_true
      end

      it "only sys_admin can change a root group's features" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        root = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: root, permissions: Model::Permissions::Manage).save!

        path = File.join(base, root.id.to_s)
        payload = {features: {signage: {ai: true}}}.to_json
        client.patch(path, body: payload, headers: headers).status_code.should eq 403
        client.patch(path, body: payload, headers: Spec::Authentication.headers).status_code.should eq 200
        Model::Group.find!(root.id.not_nil!).features["signage"]["ai"].as_bool.should be_true
      end

      it "rejects features for a subsystem the group doesn't participate in" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        root = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!

        result = client.patch(File.join(base, root.id.to_s), body: {features: {events: {catering: true}}}.to_json, headers: Spec::Authentication.headers)
        result.status_code.should eq 422
      end
    end
  end
end
