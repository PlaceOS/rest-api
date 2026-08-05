require "../helper"

# GET the oauth application index, returning the ids in response order.
# The PG-backed search is synchronous — no retry polling needed.
def oauth_app_index_ids(path : String, headers : HTTP::Headers) : Array(String)
  response = client.get(path, headers: headers)
  response.status_code.should eq 200
  Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_i64.to_s)
end

module PlaceOS::Api
  describe OAuthApplications do
    base = OAuthApplications.base_route

    ::Spec.before_each do
      clear_group_tables
      Model::DoorkeeperApplication.clear
    end

    describe "index", tags: "search" do
      Spec.test_base_index(Model::DoorkeeperApplication, OAuthApplications)
    end

    describe "index access" do
      it "lets sys_admin see every application across authorities" do
        common_authority = Model::Authority.find_by_domain("localhost").not_nil!
        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!

        own = Model::Generator.doorkeeper_application(owner: common_authority).save!
        foreign = Model::Generator.doorkeeper_application(owner: other_authority).save!

        ids = oauth_app_index_ids(base, Spec::Authentication.headers)
        ids.should contain(own.id.to_s)
        ids.should contain(foreign.id.to_s)
      end

      it "sys_admin can filter by authority_id" do
        common_authority = Model::Authority.find_by_domain("localhost").not_nil!
        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!

        own = Model::Generator.doorkeeper_application(owner: common_authority).save!
        foreign = Model::Generator.doorkeeper_application(owner: other_authority).save!

        params = HTTP::Params.encode({"authority_id" => other_authority.id.as(String)})
        ids = oauth_app_index_ids("#{base}?#{params}", Spec::Authentication.headers)
        ids.should contain(foreign.id.to_s)
        ids.should_not contain(own.id.to_s)
      end

      it "regular user with no subsystem_access only sees apps without subsystems" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        common = Model::Generator.doorkeeper_application(owner: authority).save!
        signage = Model::Generator.doorkeeper_application(owner: authority, subsystems: ["signage"]).save!

        ids = oauth_app_index_ids(base, headers)
        ids.should contain(common.id.to_s)
        ids.should_not contain(signage.id.to_s)
      end

      it "regular user with subsystems sees their matching apps and the common ones, not unrelated subsystems" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        signage = Model::Generator.doorkeeper_application(owner: authority, subsystems: ["signage"]).save!
        events = Model::Generator.doorkeeper_application(owner: authority, subsystems: ["events"]).save!
        common = Model::Generator.doorkeeper_application(owner: authority).save!

        ids = oauth_app_index_ids(base, headers)
        ids.should contain(signage.id.to_s)
        ids.should contain(common.id.to_s)
        ids.should_not contain(events.id.to_s)
      end

      it "ignores authority_id from non-admin callers (forces own authority)" do
        own_authority = Model::Authority.find_by_domain("localhost").not_nil!
        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!

        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        own_common = Model::Generator.doorkeeper_application(owner: own_authority).save!
        # An app on the OTHER authority that, if `authority_id` were
        # honoured for non-admin callers, the caller could enumerate.
        foreign_common = Model::Generator.doorkeeper_application(owner: other_authority).save!

        params = HTTP::Params.encode({"authority_id" => other_authority.id.as(String)})
        ids = oauth_app_index_ids("#{base}?#{params}", headers)
        ids.should contain(own_common.id.to_s)
        ids.should_not contain(foreign_common.id.to_s)
      end

      it "q search combines with the non-admin subsystem gating" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target_name = "app #{random_name}"
        common = Model::Generator.doorkeeper_application(owner: authority, name: target_name).save!
        other_common = Model::Generator.doorkeeper_application(owner: authority).save!
        # matches q but is subsystem-gated away from this user
        gated = Model::Generator.doorkeeper_application(
          owner: authority, name: "#{target_name} gated", subsystems: ["signage"]
        ).save!

        params = HTTP::Params.encode({"q" => target_name})
        ids = oauth_app_index_ids("#{base}?#{params}", headers)
        ids.should contain(common.id.to_s)
        ids.should_not contain(other_common.id.to_s)
        ids.should_not contain(gated.id.to_s)
      end
    end

    describe "show / write actions remain admin-only" do
      it "rejects show for non-admin users" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        app = Model::Generator.doorkeeper_application(owner: authority).save!

        result = client.get(File.join(base, app.id.to_s), headers: headers)
        result.status_code.should eq 403
      end
    end
  end
end
