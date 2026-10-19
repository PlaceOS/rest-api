require "../helper"

module PlaceOS::Api
  describe History do
    base = History.base_route

    before_each { Model::History.clear }

    describe "metadata" do
      it "attributes changes to the user and client of the request" do
        user, headers = Spec::Authentication.authentication
        headers["X-App-Id"] = "app-1"
        headers["X-App-Name"] = "backoffice"
        headers["X-App-Date"] = "2026-10-20"
        headers["X-App-Build"] = "abc123"
        headers["User-Agent"] = "Spec Browser"
        headers["X-Forwarded-For"] = "10.0.0.1"

        result = client.post(Zones.base_route, body: Model::Generator.zone.to_json, headers: headers)
        result.status_code.should eq 201
        zone = Model::Zone.from_trusted_json(result.body)

        entry = zone.change_history.to_a.first
        entry.action.should eq "create"
        entry.user_id.should eq user.id
        entry.user_email.should eq user.email.to_s

        metadata = entry.metadata
        metadata.user_name.should eq user.name
        metadata.app_id.should eq "app-1"
        metadata.app_name.should eq "backoffice"
        metadata.app_date.should eq "2026-10-20"
        metadata.app_build.should eq "abc123"
        metadata.user_agent.should eq "Spec Browser"
        metadata.ip.should eq "10.0.0.1"
        metadata.request_id.should eq result.headers["X-Request-ID"]
        metadata.api_key_id.should be_nil

        Model::History.current_metadata.should be_nil
      end

      it "records the API key used" do
        user, headers = Spec::Authentication.x_api_authentication
        api_key = Model::ApiKey.find_key!(headers["X-API-Key"])
        api_key.permissions = Model::UserJWT::Permissions::Admin
        api_key.save!

        result = client.post(Zones.base_route, body: Model::Generator.zone.to_json, headers: headers)
        result.status_code.should eq 201
        zone = Model::Zone.from_trusted_json(result.body)

        entry = zone.change_history.to_a.first
        entry.user_id.should eq user.id
        entry.metadata.api_key_id.should eq api_key.id
        entry.metadata.api_key_name.should eq api_key.name
      end
    end

    describe "index" do
      it "requires an admin" do
        result = client.get(base, headers: Spec::Authentication.headers(sys_admin: false, support: true))
        result.status_code.should eq 403
      end

      it "filters changes, newest first" do
        zone = Model::Generator.zone.save!
        zone.name = "renamed"
        zone.save!
        system = Model::Generator.control_system.save!
        old = Model::Generator.history(resource_id: "zone-old", created_at: 2.days.ago).save!
        Model::Generator.history(resource_id: "zone-group", correlation_id: "group-1").save!

        query = ->(params : Hash(String, String)) do
          result = client.get("#{base}?#{HTTP::Params.encode(params)}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          Array(Model::History).from_json(result.body)
        end

        entries = query.call({"resource_types" => "zone", "resource_id" => zone.id.as(String)})
        entries.map(&.action).should eq ["update", "create"]

        query.call({"resource_types" => "sys"}).map(&.resource_id).should eq [system.id]
        query.call({"resource_types" => "zone,sys", "exclude_resource_types" => "zone"}).map(&.resource_id).should eq [system.id]
        query.call({"correlation_id" => "group-1"}).map(&.resource_id).should eq ["zone-group"]
        query.call({"resource_id" => zone.id.as(String), "actions" => "update"}).map(&.resource_id).should eq [zone.id]
        query.call({"period_end" => 1.day.ago.to_unix.to_s}).map(&.id).should eq [old.id]
        query.call({"period_start" => 1.day.ago.to_unix.to_s}).map(&.id).should_not contain(old.id)
      end

      it "filters by user and paginates" do
        user, headers = Spec::Authentication.authentication
        3.times do
          client.post(Zones.base_route, body: Model::Generator.zone.to_json, headers: headers).status_code.should eq 201
        end
        Model::Generator.zone.save!

        result = client.get("#{base}?user_id=#{user.id}&limit=2", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        result.headers["X-Total-Count"].should eq "3"
        result.headers["Link"].should contain("offset=2")
        Array(Model::History).from_json(result.body).map(&.user_id).should eq [user.id, user.id]
      end
    end

    describe "show" do
      it "returns an entry" do
        entry = Model::Generator.history.save!
        result = client.get("#{base}#{entry.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        Model::History.from_trusted_json(result.body).id.should eq entry.id
      end
    end

    describe "undelete" do
      it "restores a deleted record" do
        headers = Spec::Authentication.headers
        zone = Model::Generator.zone
        zone.description = "restore me"
        zone.save!
        client.delete("#{Zones.base_route}#{zone.id}", headers: headers).status_code.should eq 202
        Model::Zone.find?(zone.id.as(String)).should be_nil

        params = HTTP::Params.encode({"resource_type" => "zone", "resource_id" => zone.id.as(String)})
        result = client.post("#{base}undelete?#{params}", headers: headers)
        result.status_code.should eq 201
        Model::Zone.from_trusted_json(result.body).id.should eq zone.id
        Model::Zone.find!(zone.id.as(String)).description.should eq "restore me"
        zone.change_history.to_a.map(&.action).should eq ["restore", "delete", "create"]

        # already restored
        client.post("#{base}undelete?#{params}", headers: headers).status_code.should eq 409
      end

      it "returns 404 when there is nothing to restore" do
        headers = Spec::Authentication.headers
        params = HTTP::Params.encode({"resource_type" => "zone", "resource_id" => "zone-missing"})
        client.post("#{base}undelete?#{params}", headers: headers).status_code.should eq 404

        params = HTTP::Params.encode({"resource_type" => "unknown", "resource_id" => "zone-missing"})
        client.post("#{base}undelete?#{params}", headers: headers).status_code.should eq 404
      end

      it "requires an admin" do
        params = HTTP::Params.encode({"resource_type" => "zone", "resource_id" => "zone-missing"})
        headers = Spec::Authentication.headers(sys_admin: false, support: true)
        client.post("#{base}undelete?#{params}", headers: headers).status_code.should eq 403
      end
    end
  end
end
