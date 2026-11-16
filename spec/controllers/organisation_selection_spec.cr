require "../helper"

private def selection_get(path, user)
  client.get(path, headers: PlaceOS::Api::Spec::Tenancy.headers(user))
end

private def selection_patch(path, user, body)
  client.patch(path, headers: PlaceOS::Api::Spec::Tenancy.headers(user), body: body.to_json)
end

private def selection_post(path, user, body)
  client.post(path, headers: PlaceOS::Api::Spec::Tenancy.headers(user), body: body.to_json)
end

module PlaceOS::Api
  describe "request organisation selection" do
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

    it "keeps unchanged requests in the ordinary caller's home organisation when grants add reach" do
      f = build.call.not_nil!
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s).save!

      result = selection_get("#{Zones.base_route}?limit=500", f.ucla.admin)
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).sort.should eq [f.ucla.org_zone.id.as(String), f.ucla.building.id.as(String)].sort
      selection_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.ucla.admin).status_code.should eq 404
      selection_get("#{Zones.base_route}#{f.acadian.org_zone.id}?organisation_id=#{f.acadian.organisation.id}", f.ucla.admin).status_code.should eq 200
    end

    it "keeps single-organisation request payloads and write ownership unchanged" do
      f = build.call.not_nil!
      result = selection_post(Zones.base_route, f.acadian.admin, {name: "Unchanged #{random_name}"})
      result.status_code.should eq 201
      JSON.parse(result.body)["organisation_id"].as_s.should eq f.acadian.organisation.id.to_s
      selection_get("#{Zones.base_route}#{f.acadian.building.id}", f.acadian.admin).status_code.should eq 200
    end

    it "requires partner staff to select an organisation for estate lists and details" do
      f = build.call.not_nil!
      [Zones.base_route, "#{Zones.base_route}#{f.acadian.org_zone.id}", Systems.base_route, Modules.base_route].each do |path|
        result = selection_get(path, f.ntt_staff.admin)
        result.status_code.should eq 400
        JSON.parse(result.body)["code"].as_s.should eq "organisation_required"
      end
    end

    it "requires management staff to select an organisation for estate requests" do
      f = build.call.not_nil!
      result = selection_get(Zones.base_route, f.placeos.admin)
      result.status_code.should eq 400
      JSON.parse(result.body)["code"].as_s.should eq "organisation_required"
      selection_get(Brokers.base_route, f.placeos.admin).status_code.should eq 200
      selection_get("#{Organisations.base_route}current", f.placeos.admin).status_code.should eq 200
    end

    it "rejects malformed, duplicate and inaccessible selectors consistently" do
      f = build.call.not_nil!
      base = "#{Zones.base_route}#{f.acadian.org_zone.id}"
      selection_get("#{base}?organisation_id=not-a-uuid", f.ntt_staff.admin).status_code.should eq 400
      selection_get("#{base}?organisation_id=#{f.acadian.organisation.id}&organisation_id=#{f.ntt_staff.organisation.id}", f.ntt_staff.admin).status_code.should eq 400
      selection_get("#{base}?organisation_id=#{UUID.random}", f.ntt_staff.admin).status_code.should eq 404
      selection_get("#{base}?organisation_id=#{f.ucla.organisation.id}", f.ntt_staff.admin).status_code.should eq 404
    end

    it "does not permit a selected sibling organisation's direct ids, updates or deletes" do
      f = build.call.not_nil!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      selection_get("#{Zones.base_route}#{f.ntt_staff.building.id}#{suffix}", f.ntt_staff.admin).status_code.should eq 404
      selection_patch("#{Zones.base_route}#{f.ntt_staff.building.id}#{suffix}", f.ntt_staff.admin, {name: "Not changed"}).status_code.should eq 404
      client.delete("#{Zones.base_route}#{f.ntt_staff.building.id}#{suffix}", headers: Spec::Tenancy.headers(f.ntt_staff.admin)).status_code.should eq 404
      Model::Zone.find!(f.ntt_staff.building.id.as(String)).name.should eq f.ntt_staff.building.name
    end

    it "owns new rows through the selection and refuses a sibling parent" do
      f = build.call.not_nil!
      path = "#{Zones.base_route}?organisation_id=#{f.acadian.organisation.id}"
      result = selection_post(path, f.ntt_staff.admin, {name: "Selected #{random_name}"})
      result.status_code.should eq 201
      JSON.parse(result.body)["organisation_id"].as_s.should eq f.acadian.organisation.id.to_s
      selection_post(path, f.ntt_staff.admin, {name: "Wrong parent #{random_name}", parent_id: f.ntt_staff.building.id}).status_code.should eq 404
    end

    it "rejects sibling systems supplied with a selected organisation to modules index" do
      f = build.call.not_nil!
      result = selection_get("#{Modules.base_route}?organisation_id=#{f.acadian.organisation.id}&control_system_id=#{f.ntt_staff.system.id}", f.ntt_staff.admin)
      result.status_code.should eq 404
    end

    it "rejects sibling authorities supplied with a selected organisation to users index" do
      f = build.call.not_nil!
      result = selection_get("#{Users.base_route}?organisation_id=#{f.acadian.organisation.id}&authority_id=#{f.ntt_staff.authority.id}", f.ntt_staff.admin)
      result.status_code.should eq 404
    end

    it "limits aggregate tags to the selected organisation" do
      f = build.call.not_nil!
      f.acadian.building.tags = Set{"building", "selected-only"}
      f.acadian.building.save!
      f.ntt_staff.building.tags = Set{"building", "sibling-only"}
      f.ntt_staff.building.save!
      result = selection_get("#{Zones.base_route}tags?organisation_id=#{f.acadian.organisation.id}", f.ntt_staff.admin)
      result.status_code.should eq 200
      result.body.should contain("selected-only")
      result.body.should_not contain("sibling-only")
    end

    it "allows ordinary callers to discover accessible organisations without exposing config or billing" do
      f = build.call.not_nil!
      f.ucla.organisation.config = {"private" => JSON::Any.new("not a selector field")}
      f.ucla.organisation.save!
      Model::Generator.grant(f.ucla.user, "organisation", f.acadian.organisation.id.to_s).save!
      result = selection_get("#{Organisations.base_route}?limit=500", f.ucla.user)
      result.status_code.should eq 200
      organisations = JSON.parse(result.body).as_a
      organisations.map(&.["id"].as_s).sort!.should eq [f.ucla.organisation.id.to_s, f.acadian.organisation.id.to_s].sort
      organisations.each do |organisation|
        organisation["config"]?.should be_nil
        organisation["payer"]?.should be_nil
      end
      current = selection_get("#{Organisations.base_route}current", f.ucla.user)
      current.status_code.should eq 200
      discovery = JSON.parse(current.body)
      discovery["organisation"]["config"]?.should be_nil
      discovery["organisation"]["payer"]?.should be_nil
      discovery["organisations"].as_a.each do |organisation|
        organisation["config"]?.should be_nil
        organisation["payer"]?.should be_nil
      end
    end

    it "keeps management-partner customer administrators in their own organisation" do
      f = build.call.not_nil!
      customer = Spec::Tenancy.org("managed.test", Model::Generator.organisation(partner: f.management).save!)
      result = selection_get("#{Organisations.base_route}current", customer.admin)
      result.status_code.should eq 200
      JSON.parse(result.body)["reach"].as_s.should eq "organisation"
      selection_get("#{Zones.base_route}#{f.ucla.building.id}?organisation_id=#{f.ucla.organisation.id}", customer.admin).status_code.should eq 404
      selection_get(Brokers.base_route, customer.admin).status_code.should eq 403
    end

    it "does not turn a read grant into write access using the home administrator flag" do
      f = build.call.not_nil!
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      selection_get("#{Zones.base_route}#{f.acadian.building.id}#{suffix}", f.ucla.admin).status_code.should eq 200
      selection_patch("#{Zones.base_route}#{f.acadian.building.id}#{suffix}", f.ucla.admin, {name: "Read must not write"}).status_code.should eq 403
      selection_post("#{Zones.base_route}#{suffix}", f.ucla.admin, {name: "Read must not create #{random_name}"}).status_code.should eq 403
      client.delete("#{Zones.base_route}#{f.acadian.building.id}#{suffix}", headers: Spec::Tenancy.headers(f.ucla.admin)).status_code.should eq 403
    end

    it "preserves the exact authority boundary of a read grant within a multi-domain organisation" do
      f = build.call.not_nil!
      other_authority = Model::Generator.authority("other.acadian.test")
      other_authority.organisation_id = f.acadian.organisation.id
      other_authority.save!
      other_user = Model::Generator.user(other_authority).save!
      Model::Generator.grant(f.ucla.admin, "authority", f.acadian.authority.id.as(String), Model::Permissions::Read).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"

      result = selection_get("#{Users.base_route}#{suffix}", f.ucla.admin)
      result.status_code.should eq 200
      ids = Spec::Tenancy.ids(result.body)
      ids.should contain(f.acadian.user.id)
      ids.should_not contain(other_user.id)
      selection_get("#{Users.base_route}#{other_user.id}#{suffix}", f.ucla.admin).status_code.should eq 404
      selection_get("#{Domains.base_route}#{other_authority.id}#{suffix}", f.ucla.admin).status_code.should eq 404
    end

    it "rejects revoked and expired grant selections on subsequent requests" do
      f = build.call.not_nil!
      grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s).save!
      path = "#{Zones.base_route}#{f.acadian.building.id}?organisation_id=#{f.acadian.organisation.id}"
      selection_get(path, f.ucla.admin).status_code.should eq 200
      grant.destroy
      selection_get(path, f.ucla.admin).status_code.should eq 404
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, expires_at: 1.minute.ago).save!
      selection_get(path, f.ucla.admin).status_code.should eq 404
    end

    it "keeps public guest token issuance domain-bound and unauthenticated under enforcement" do
      f = build.call.not_nil!
      f.acadian.system.public = true
      f.acadian.system.save!
      f.acadian.authority.internals_will_change!
      f.acadian.authority.internals["recaptcha_skip"] = JSON::Any.new(true)
      f.acadian.authority.save!
      result = client.post("#{PublicEvents.base_route}guest_token/#{f.acadian.system.id}",
        headers: HTTP::Headers{"Host" => f.acadian.authority.domain, "Content-Type" => "application/json"},
        body: {captcha: "skip", name: "Guest", email: "guest@external.test"}.to_json)

      # An absent JWT_SECRET disables issuance, but organisation enforcement
      # must not turn this public route into an authenticated resource route.
      result.status_code.should eq(PublicEvents::JWT_SECRET ? 200 : 503)
    end

    it "preserves invited guests' home-domain public events without allowing foreign organisation selection" do
      f = build.call.not_nil!
      f.acadian.system.public = true
      f.acadian.system.save!
      token = Model::UserJWT.new(
        iss: Model::UserJWT::ISSUER,
        iat: 5.minutes.ago,
        exp: 1.hour.from_now,
        domain: f.acadian.authority.domain,
        id: f.acadian.user.id.as(String),
        user: Model::UserJWT::Metadata.new(name: "Invited guest", email: "guest@external.test",
          permissions: Model::UserJWT::Permissions::User, roles: [f.acadian.system.id.as(String)]),
        scope: [Model::UserJWT::Scope::GUEST],
      )
      headers = HTTP::Headers{"Host" => f.acadian.authority.domain, "Content-Type" => "application/json", "Authorization" => "Bearer #{token.encode}"}
      path = "#{PublicEvents.base_route}#{f.acadian.system.id}/events"
      result = client.get(path, headers: headers)
      result.status_code.should eq 200
      JSON.parse(result.body).as_a.should be_empty
      client.get("#{path}?organisation_id=#{f.ucla.organisation.id}", headers: headers).status_code.should eq 404
    end

    it "keeps discovery restricted to real reach even when resource enforcement is disabled" do
      f = build.call.not_nil!
      Utils::Tenancy.enforce = false
      result = selection_get("#{Organisations.base_route}?limit=500", f.acadian.user)
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).should eq [f.acadian.organisation.id.to_s]
      selection_get("#{Organisations.base_route}#{f.acadian.organisation.id}", f.acadian.user).status_code.should eq 200
      selection_get("#{Organisations.base_route}#{f.ucla.organisation.id}", f.acadian.user).status_code.should eq 404
    end

    it "retains legacy request behaviour when enforcement is disabled" do
      f = build.call.not_nil!
      Utils::Tenancy.enforce = false
      selection_get(Zones.base_route, f.ntt_staff.admin).status_code.should eq 200
      selection_get("#{Zones.base_route}#{f.ucla.building.id}", f.acadian.admin).status_code.should eq 200
    end
  end
end
