require "../helper"

private def tenancy_get(path, user)
  client.get(path, headers: PlaceOS::Api::Spec::Tenancy.headers(user))
end

private def tenancy_post(path, user, body)
  client.post(path, headers: PlaceOS::Api::Spec::Tenancy.headers(user), body: body.to_json)
end

module PlaceOS::Api
  # PPT-526: who can see and touch what across organisations on a shared cluster
  describe "tenancy" do
    before_each { Utils::Tenancy.enforce = true }
    after_each { Utils::Tenancy.enforce = false }

    describe "reach" do
      it "resolves cluster, partner and organisation reach" do
        f = Spec::Tenancy.build

        cluster = JSON.parse(tenancy_get("#{Organisations.base_route}current", f.placeos.admin).body)
        cluster["reach"].should eq "cluster"
        cluster["enforcing"].as_bool.should be_true
        cluster["organisations"].raw.should be_nil

        partner = JSON.parse(tenancy_get("#{Organisations.base_route}current", f.ntt_staff.admin).body)
        partner["reach"].should eq "partner"
        partner["organisations"].as_a.map(&.["id"].to_s).sort!.should eq [f.ntt_staff.organisation.id.to_s, f.acadian.organisation.id.to_s].sort

        org = JSON.parse(tenancy_get("#{Organisations.base_route}current", f.acadian.admin).body)
        org["reach"].should eq "organisation"
        org["organisations"].as_a.map(&.["id"].to_s).should eq [f.acadian.organisation.id.to_s]

        plain = JSON.parse(tenancy_get("#{Organisations.base_route}current", f.placeos.user).body)
        plain["reach"].should eq "organisation"
      end
    end

    describe "estate lists" do
      it "scopes zones, systems and modules to the caller's organisations" do
        f = Spec::Tenancy.build

        zones = Spec::Tenancy.ids(tenancy_get(Zones.base_route, f.acadian.admin).body)
        zones.should contain(f.acadian.org_zone.id)
        zones.should_not contain(f.ucla.org_zone.id)
        zones.should_not contain(f.unowned_zone.id)

        partner_zones = Spec::Tenancy.ids(tenancy_get(Zones.base_route, f.ntt_staff.support).body)
        partner_zones.should contain(f.acadian.org_zone.id)
        partner_zones.should contain(f.ntt_staff.org_zone.id)
        partner_zones.should_not contain(f.ucla.org_zone.id)

        cluster_zones = Spec::Tenancy.ids(tenancy_get(Zones.base_route, f.placeos.admin).body)
        cluster_zones.should contain(f.ucla.org_zone.id)
        cluster_zones.should contain(f.unowned_zone.id)

        systems = Spec::Tenancy.ids(tenancy_get(Systems.base_route, f.ucla.admin).body)
        systems.should eq [f.ucla.system.id]

        modules = Spec::Tenancy.ids(tenancy_get(Modules.base_route, f.ucla.admin).body)
        modules.should eq [f.ucla.mod.id]

        tenancy_get("#{Zones.base_route}tags", f.acadian.admin).status_code.should eq 200
      end

      it "answers 404 for another organisation's rows and 200 for its own" do
        f = Spec::Tenancy.build

        tenancy_get("#{Zones.base_route}#{f.ucla.org_zone.id}", f.acadian.admin).status_code.should eq 404
        tenancy_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.acadian.admin).status_code.should eq 200
        tenancy_get("#{Systems.base_route}#{f.ucla.system.id}", f.acadian.admin).status_code.should eq 404
        tenancy_get("#{Modules.base_route}#{f.ucla.mod.id}", f.acadian.admin).status_code.should eq 404
        tenancy_get("#{Zones.base_route}#{f.unowned_zone.id}", f.acadian.admin).status_code.should eq 404

        # partner staff reach their client, not a stranger
        tenancy_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.ntt_staff.admin).status_code.should eq 200
        tenancy_get("#{Zones.base_route}#{f.ucla.org_zone.id}", f.ntt_staff.admin).status_code.should eq 404

        # cluster admins reach everything, unowned rows included
        tenancy_get("#{Zones.base_route}#{f.ucla.org_zone.id}", f.placeos.admin).status_code.should eq 200
        tenancy_get("#{Zones.base_route}#{f.unowned_zone.id}", f.placeos.admin).status_code.should eq 200
      end

      it "only logs when enforcement is off" do
        f = Spec::Tenancy.build
        Utils::Tenancy.enforce = false
        tenancy_get("#{Zones.base_route}#{f.ucla.org_zone.id}", f.acadian.admin).status_code.should eq 200
      end
    end

    describe "estate writes" do
      it "owns new zones through the caller or the parent" do
        f = Spec::Tenancy.build

        root = tenancy_post(Zones.base_route, f.acadian.admin, {name: "Acadian root #{random_name}", tags: ["building"]})
        root.status_code.should eq 201
        JSON.parse(root.body)["organisation_id"].to_s.should eq f.acadian.organisation.id.to_s

        child = tenancy_post(Zones.base_route, f.acadian.admin, {name: "Level #{random_name}", parent_id: f.acadian.building.id})
        child.status_code.should eq 201
        JSON.parse(child.body)["organisation_id"].to_s.should eq f.acadian.organisation.id.to_s

        foreign_parent = tenancy_post(Zones.base_route, f.acadian.admin, {name: "Sneaky #{random_name}", parent_id: f.ucla.building.id})
        foreign_parent.status_code.should eq 404

        named = client.post("#{Zones.base_route}?organisation_id=#{f.ucla.organisation.id}", headers: Spec::Tenancy.headers(f.placeos.admin), body: {name: "UCLA root #{random_name}", tags: ["building"]}.to_json)
        named.status_code.should eq 201
        JSON.parse(named.body)["organisation_id"].to_s.should eq f.ucla.organisation.id.to_s

        client.post("#{Zones.base_route}?organisation_id=#{f.ucla.organisation.id}", headers: Spec::Tenancy.headers(f.acadian.admin), body: {name: "Not mine #{random_name}"}.to_json).status_code.should eq 403
      end

      it "owns new systems through their zones and refuses mixed zones" do
        f = Spec::Tenancy.build

        own = tenancy_post(Systems.base_route, f.acadian.admin, {name: "Room #{random_name}", zones: [f.acadian.building.id]})
        own.status_code.should eq 201
        JSON.parse(own.body)["organisation_id"].to_s.should eq f.acadian.organisation.id.to_s

        tenancy_post(Systems.base_route, f.acadian.admin, {name: "Room #{random_name}", zones: [f.ucla.building.id]}).status_code.should eq 404

        mixed = tenancy_post(Systems.base_route, f.placeos.admin, {name: "Room #{random_name}", zones: [f.acadian.building.id, f.ucla.building.id]})
        mixed.status_code.should eq 422
      end

      it "keeps modules inside the system's organisation" do
        f = Spec::Tenancy.build

        attach = client.put("#{Systems.base_route}#{f.acadian.system.id}/module/#{f.ucla.mod.id}", headers: Spec::Tenancy.headers(f.acadian.admin))
        attach.status_code.should eq 404

        attach = client.put("#{Systems.base_route}#{f.ucla.system.id}/module/#{f.ucla.mod.id}", headers: Spec::Tenancy.headers(f.ucla.admin))
        attach.status_code.should eq 200
      end
    end

    describe "domains and users" do
      it "lists and creates domains within reach" do
        f = Spec::Tenancy.build

        domains = Spec::Tenancy.ids(tenancy_get(Domains.base_route, f.acadian.admin).body)
        domains.should eq [f.acadian.authority.id]
        tenancy_get("#{Domains.base_route}#{f.ucla.authority.id}", f.acadian.admin).status_code.should eq 404

        created = tenancy_post(Domains.base_route, f.acadian.admin, {name: "Acadian two", domain: "two.acadian.test"})
        created.status_code.should eq 201
        JSON.parse(created.body)["organisation_id"].to_s.should eq f.acadian.organisation.id.to_s

        staff = client.post("#{Domains.base_route}?organisation_id=#{f.ucla.organisation.id}", headers: Spec::Tenancy.headers(f.placeos.admin), body: {name: "UCLA two", domain: "two.ucla.test"}.to_json)
        staff.status_code.should eq 201
        JSON.parse(staff.body)["organisation_id"].to_s.should eq f.ucla.organisation.id.to_s

        moved = client.patch("#{Domains.base_route}#{f.acadian.authority.id}?organisation_id=#{f.ucla.organisation.id}", headers: Spec::Tenancy.headers(f.acadian.admin), body: {name: "renamed"}.to_json)
        moved.status_code.should eq 403
      end

      it "lists users within reach only" do
        f = Spec::Tenancy.build

        users = Spec::Tenancy.ids(tenancy_get(Users.base_route, f.acadian.admin).body)
        users.should contain(f.acadian.user.id)
        users.should_not contain(f.ucla.user.id)

        tenancy_get("#{Users.base_route}?authority_id=#{f.ucla.authority.id}", f.acadian.admin).status_code.should eq 404
        tenancy_get("#{Users.base_route}#{f.ucla.user.id}", f.acadian.admin).status_code.should eq 404

        partner_users = Spec::Tenancy.ids(tenancy_get(Users.base_route, f.ntt_staff.admin).body)
        partner_users.should contain(f.acadian.user.id)
        partner_users.should_not contain(f.ucla.user.id)
      end
    end

    describe "cluster-only resources" do
      it "hides brokers and trigger templates' writes from organisation admins" do
        f = Spec::Tenancy.build

        tenancy_get(Brokers.base_route, f.acadian.admin).status_code.should eq 403
        tenancy_get(Brokers.base_route, f.placeos.admin).status_code.should eq 200

        template = tenancy_post(Triggers.base_route, f.acadian.admin, {name: "Template #{random_name}"})
        template.status_code.should eq 403
        template = tenancy_post(Triggers.base_route, f.placeos.admin, {name: "Template #{random_name}"})
        template.status_code.should eq 201

        # templates are readable by every organisation
        templates = Spec::Tenancy.ids(tenancy_get(Triggers.base_route, f.acadian.admin).body)
        templates.should contain(JSON.parse(template.body)["id"].to_s)

        bound = tenancy_post(Triggers.base_route, f.acadian.admin, {name: "Bound #{random_name}", control_system_id: f.acadian.system.id})
        bound.status_code.should eq 201
        JSON.parse(bound.body)["organisation_id"].to_s.should eq f.acadian.organisation.id.to_s
        Spec::Tenancy.ids(tenancy_get(Triggers.base_route, f.ucla.admin).body).should_not contain(JSON.parse(bound.body)["id"].to_s)
      end
    end

    describe "organisations, partners and grants" do
      it "lets cluster admins manage the hierarchy and others read their own" do
        f = Spec::Tenancy.build

        partner = tenancy_post(Partners.base_route, f.placeos.admin, {name: "Integrator #{random_name}"})
        partner.status_code.should eq 201
        partner_id = JSON.parse(partner.body)["id"].to_s

        organisation = client.post("#{Organisations.base_route}?partner_staff=true", headers: Spec::Tenancy.headers(f.placeos.admin), body: {name: "Integrator staff #{random_name}", partner_id: partner_id}.to_json)
        organisation.status_code.should eq 201
        JSON.parse(organisation.body)["partner_staff"].as_bool.should be_true

        tenancy_post(Partners.base_route, f.acadian.admin, {name: "Nope #{random_name}"}).status_code.should eq 403

        Spec::Tenancy.ids(tenancy_get(Organisations.base_route, f.acadian.admin).body).should eq [f.acadian.organisation.id.to_s]
        Spec::Tenancy.ids(tenancy_get(Partners.base_route, f.acadian.admin).body).should eq [f.ntt.id.to_s]
        tenancy_get("#{Partners.base_route}#{f.management.id}", f.acadian.admin).status_code.should eq 404

        client.patch("#{Organisations.base_route}#{f.acadian.organisation.id}", headers: Spec::Tenancy.headers(f.acadian.admin), body: {name: "renamed"}.to_json).status_code.should eq 403
      end

      it "widens reach through live grants" do
        f = Spec::Tenancy.build

        tenancy_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.ucla.admin).status_code.should eq 404

        granted = tenancy_post(Grants.base_route, f.placeos.admin, {user_id: f.ucla.admin.id, scope_type: "organisation", scope_id: f.acadian.organisation.id.to_s, permissions: 1})
        granted.status_code.should eq 201
        tenancy_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.ucla.admin).status_code.should eq 200

        client.delete("#{Grants.base_route}#{JSON.parse(granted.body)["id"]}", headers: Spec::Tenancy.headers(f.placeos.admin)).status_code.should eq 202
        tenancy_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.ucla.admin).status_code.should eq 404

        expired = tenancy_post(Grants.base_route, f.placeos.admin, {user_id: f.ucla.admin.id, scope_type: "organisation", scope_id: f.acadian.organisation.id.to_s, permissions: 1, expires_at: 1.hour.ago})
        expired.status_code.should eq 201
        tenancy_get("#{Zones.base_route}#{f.acadian.org_zone.id}", f.ucla.admin).status_code.should eq 404

        # an organisation admin may grant into their own organisation but not a stranger's
        tenancy_post(Grants.base_route, f.acadian.admin, {user_id: f.ucla.admin.id, scope_type: "organisation", scope_id: f.acadian.organisation.id.to_s}).status_code.should eq 201
        tenancy_post(Grants.base_route, f.acadian.admin, {user_id: f.acadian.admin.id, scope_type: "organisation", scope_id: f.ucla.organisation.id.to_s}).status_code.should eq 403
      end

      it "claims an unowned zone tree for an organisation" do
        f = Spec::Tenancy.build

        claimed = tenancy_post("#{Organisations.base_route}#{f.ucla.organisation.id}/claim", f.placeos.admin, {zone_ids: [f.unowned_zone.id]})
        claimed.status_code.should eq 200
        result = JSON.parse(claimed.body)
        result["zones"].should eq 1
        result["systems"].should eq 1

        Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should eq f.ucla.organisation.id
        Model::ControlSystem.find!(f.unowned_system.id.as(String)).organisation_id.should eq f.ucla.organisation.id
        tenancy_get("#{Zones.base_route}#{f.unowned_zone.id}", f.ucla.admin).status_code.should eq 200
      end
    end
  end
end
