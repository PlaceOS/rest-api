require "../helper"

module PlaceOS::Api
  describe OAuthApplications do
    base = OAuthApplications.base_route

    ::Spec.before_each do
      clear_group_tables
      Model::DoorkeeperApplication.clear
    end

    describe "index access" do
      it "lets sys_admin see every application across authorities" do
        common_authority = Model::Authority.find_by_domain("localhost").not_nil!
        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!

        own = Model::Generator.doorkeeper_application(owner: common_authority).save!
        foreign = Model::Generator.doorkeeper_application(owner: other_authority).save!

        sleep 1.second
        refresh_elastic(Model::DoorkeeperApplication.table_name)
        found = until_expected("GET", base, Spec::Authentication.headers) do |response|
          response.success? && begin
            ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_i.to_s)
            ids.includes?(own.id.to_s) && ids.includes?(foreign.id.to_s)
          end
        end
        found.should be_true
      end

      it "regular user with no subsystem_access only sees apps without subsystems" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        common = Model::Generator.doorkeeper_application(owner: authority).save!
        signage = Model::Generator.doorkeeper_application(owner: authority, subsystems: ["signage"]).save!

        sleep 1.second
        refresh_elastic(Model::DoorkeeperApplication.table_name)
        found = until_expected("GET", base, headers) do |response|
          response.success? && begin
            ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_i.to_s)
            ids.includes?(common.id.to_s) && !ids.includes?(signage.id.to_s)
          end
        end
        found.should be_true
      end

      it "regular user with subsystems sees their matching apps and the common ones, not unrelated subsystems" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        signage = Model::Generator.doorkeeper_application(owner: authority, subsystems: ["signage"]).save!
        events = Model::Generator.doorkeeper_application(owner: authority, subsystems: ["events"]).save!
        common = Model::Generator.doorkeeper_application(owner: authority).save!

        sleep 1.second
        refresh_elastic(Model::DoorkeeperApplication.table_name)
        found = until_expected("GET", base, headers) do |response|
          response.success? && begin
            ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_i.to_s)
            ids.includes?(signage.id.to_s) &&
              ids.includes?(common.id.to_s) &&
              !ids.includes?(events.id.to_s)
          end
        end
        found.should be_true
      end

      it "ignores authority_id from non-admin callers (forces own authority)" do
        own_authority = Model::Authority.find_by_domain("localhost").not_nil!
        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!

        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        own_common = Model::Generator.doorkeeper_application(owner: own_authority).save!
        # An app on the OTHER authority that, if `authority_id` were
        # honoured for non-admin callers, the caller could enumerate.
        foreign_common = Model::Generator.doorkeeper_application(owner: other_authority).save!

        sleep 1.second
        refresh_elastic(Model::DoorkeeperApplication.table_name)
        params = HTTP::Params.encode({"authority_id" => other_authority.id.as(String)})
        found = until_expected("GET", "#{base}?#{params}", headers) do |response|
          response.success? && begin
            ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_i.to_s)
            ids.includes?(own_common.id.to_s) && !ids.includes?(foreign_common.id.to_s)
          end
        end
        found.should be_true
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
