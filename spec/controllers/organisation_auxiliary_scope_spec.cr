require "../helper"

module PlaceOS::Api
  describe "organisation ownership beyond estate lists" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    build = -> { fixture = Spec::Tenancy.build }

    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "preserves existing API keys with stored privileges above their owner's role" do
      f = build.call.not_nil!
      key = Model::ApiKey.new(name: "Existing #{random_name}")
      key.user = f.acadian.user
      key.permissions = Model::UserJWT::Permissions::Admin
      secret = key.x_api_key.not_nil!
      key.save!
      headers = Spec::Tenancy.headers(f.acadian.user)
      headers.delete("Authorization")
      headers["X-API-Key"] = secret
      result = client.post(Zones.base_route, headers: headers, body: {name: "Key-owned #{random_name}"}.to_json)
      result.status_code.should eq 201
      JSON.parse(result.body)["organisation_id"].as_s.should eq f.acadian.organisation.id.to_s
    end

    it "checks changed API key users before saving" do
      f = build.call.not_nil!
      key = Model::ApiKey.new(name: "Stay here #{random_name}")
      key.user = f.acadian.user
      key.save!
      result = client.patch("#{ApiKeys.base_route}#{key.id}?organisation_id=#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {user_id: f.ntt_staff.user.id}.to_json)
      result.status_code.should eq 404
      Model::ApiKey.find!(key.id.as(String)).user_id.should eq f.acadian.user.id
    end

    it "checks changed OAuth owners before saving" do
      f = build.call.not_nil!
      app = Model::Generator.doorkeeper_application(owner: f.acadian.authority).save!
      result = client.patch("#{OAuthApplications.base_route}#{app.id}?organisation_id=#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {owner_id: f.ntt_staff.authority.id}.to_json)
      result.status_code.should eq 404
      Model::DoorkeeperApplication.find!(app.id.not_nil!).owner_id.should eq f.acadian.authority.id
    end

    it "filters metadata children individually when a legacy tree crosses organisations" do
      f = build.call.not_nil!
      f.ntt_staff.building.parent_id = f.acadian.org_zone.id
      f.ntt_staff.building.save!
      result = client.get("#{Metadata.base_route}/#{f.acadian.org_zone.id}/children?organisation_id=#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      result.status_code.should eq 200
      ids = JSON.parse(result.body).as_a.map(&.["zone"]["id"].as_s)
      ids.should contain(f.acadian.building.id)
      ids.should_not contain(f.ntt_staff.building.id)
    end

    it "keeps organisation history available and hides sibling changes" do
      f = build.call.not_nil!
      result = client.get("#{History.base_route}?resource_types=zone", headers: Spec::Tenancy.headers(f.acadian.admin))
      result.status_code.should eq 200
      ids = JSON.parse(result.body).as_a.map(&.["resource_id"].as_s)
      ids.should contain(f.acadian.building.id)
      ids.should_not contain(f.ntt_staff.building.id)
    end

    it "scopes deleted history and restoration using the recorded owner" do
      f = build.call.not_nil!
      zone = Model::Generator.zone.tap { |z| z.name = "Deleted #{random_name}"; z.organisation_id = f.acadian.organisation.id }.save!
      id = zone.id.as(String)
      zone.destroy
      suffix = "organisation_id=#{f.acadian.organisation.id}"
      result = client.get("#{History.base_route}?resource_id=#{id}&#{suffix}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      result.status_code.should eq 200
      JSON.parse(result.body).as_a.map(&.["action"].as_s).should contain("delete")
      restored = client.post("#{History.base_route}undelete?resource_type=zone&resource_id=#{id}&#{suffix}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      restored.status_code.should eq 201
      Model::Zone.find!(id).organisation_id.should eq f.acadian.organisation.id
    end

    it "refuses unrestricted Flux for organisation users before contacting Influx" do
      f = build.call.not_nil!
      headers = Spec::Tenancy.headers(f.acadian.admin)
      headers["Content-Type"] = "application/vnd.flux"
      result = client.post("#{Flux.base_route.rstrip('/')}/query", headers: headers, body: "from(bucket: \"place\") |> range(start: -1m)")
      result.status_code.should eq 403
    end
  end
end
