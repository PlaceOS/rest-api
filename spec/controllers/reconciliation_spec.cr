require "../helper"

module PlaceOS::Api
  describe "cluster ownership reconciliation" do
    base = "/api/engine/v2/reconciliation"
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        PgORM::Database.connection do |db|
          exists = db.query_one("SELECT to_regclass('tenancy_reconciliations') IS NOT NULL", args: [] of PgORM::Value, &.read(Bool))
          db.exec("DELETE FROM tenancy_reconciliations WHERE actor_id = $1", args: [f.placeos.admin.id.as(String)]) if exists
        end
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "exposes unowned inventory only to live structural cluster administrators" do
      f = fixture = Spec::Tenancy.build
      path = "#{base}?resource_type=zone&resource_id=#{f.unowned_zone.id}"
      result = client.get(path, headers: Spec::Tenancy.headers(f.placeos.admin))
      result.status_code.should eq 200
      items = JSON.parse(result.body).as_a
      items.map(&.["resource_id"].as_s).should contain(f.unowned_zone.id)
      result.headers["X-Total-Count"].should eq "1"
      [f.placeos.support, f.ntt_staff.admin, f.acadian.admin, f.ucla.user].each do |actor|
        client.get(path, headers: Spec::Tenancy.headers(actor)).status_code.should eq 403
      end
      Model::Generator.grant(f.ucla.admin, "organisation", f.placeos.organisation.id.to_s, Model::Permissions::Manage).save!
      client.get(path, headers: Spec::Tenancy.headers(f.ucla.admin)).status_code.should eq 403
      stale = Spec::Tenancy.headers(f.placeos.admin)
      f.placeos.admin.sys_admin = false
      f.placeos.admin.support = true
      f.placeos.admin.save!
      client.get(path, headers: stale).status_code.should eq 403
    end

    it "previews a complete unowned tree without changing ownership" do
      f = fixture = Spec::Tenancy.build
      child = Model::Generator.zone.tap(&.parent_id=(f.unowned_zone.id)).save!
      mod = Model::Generator.module(control_system: f.unowned_system).save!
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
      preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["blockers"].as_a.should be_empty
      changes = plan["changes"].as_a.map(&.["resource_id"].as_s)
      [f.unowned_zone.id, child.id, f.unowned_system.id, mod.id].each { |id| changes.should contain(id) }
      Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should be_nil
      Model::ControlSystem.find!(f.unowned_system.id.as(String)).organisation_id.should be_nil
      Model::Module.find!(mod.id.as(String)).organisation_id.should be_nil
    end

    it "applies an exact preview atomically and replays its durable idempotency result" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      digest = JSON.parse(preview.body)["digest"].as_s
      body = {operations: operations, digest: digest, idempotency_key: UUID.random.to_s}.to_json
      applied = client.post("#{base}/apply", headers: headers, body: body)
      applied.status_code.should eq 200
      Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should eq f.acadian.organisation.id
      Model::ControlSystem.find!(f.unowned_system.id.as(String)).organisation_id.should eq f.acadian.organisation.id
      replay = client.post("#{base}/apply", headers: headers, body: body)
      replay.status_code.should eq 200
      JSON.parse(replay.body).should eq JSON.parse(applied.body)
      PgORM::Database.connection do |db|
        db.query_one("SELECT count(*) FROM tenancy_reconciliations WHERE actor_id = $1", args: [f.placeos.admin.id.as(String)], &.read(Int64)).should eq 1
      end
      changed_key_use = {operations: [] of String, digest: digest, idempotency_key: JSON.parse(body)["idempotency_key"].as_s}.to_json
      client.post("#{base}/apply", headers: headers, body: changed_key_use).status_code.should eq 409
    end

    it "rejects stale reference membership without partially assigning the tree" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      Model::Generator.zone.tap(&.parent_id=(f.unowned_zone.id)).save!
      applied = client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: JSON.parse(preview.body)["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json)
      applied.status_code.should eq 409
      Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should be_nil
      Model::ControlSystem.find!(f.unowned_system.id.as(String)).organisation_id.should be_nil
    end

    it "blocks a foreign descendant and leaves every original owner unchanged" do
      f = fixture = Spec::Tenancy.build
      f.ucla.building.parent_id = f.unowned_zone.id
      f.ucla.building.save!
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["blockers"].as_a.should_not be_empty
      client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: plan["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json).status_code.should eq 409
      Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should be_nil
      Model::Zone.find!(f.ucla.building.id.as(String)).organisation_id.should eq f.ucla.organisation.id
    end

    it "requires a matching source owner when correcting an already owned resource" do
      f = fixture = Spec::Tenancy.build
      zone = Model::Generator.zone.tap(&.organisation_id = f.acadian.organisation.id).save!
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "reassign", resource_type: "zone", resource_ids: [zone.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["blockers"].as_a.should be_empty
      client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: plan["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json).status_code.should eq 200
      Model::Zone.find!(zone.id.as(String)).organisation_id.should eq f.ucla.organisation.id
      mismatch = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      mismatch.status_code.should eq 200
      JSON.parse(mismatch.body)["blockers"].as_a.should_not be_empty
    end

    it "moves a domain with its exclusive estate while preserving identity and configuration" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.placeos.admin)
      original_config = f.acadian.authority.config.to_json
      operations = [{kind: "move_domain", resource_type: "authority", resource_ids: [f.acadian.authority.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["blockers"].as_a.should be_empty
      client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: plan["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json).status_code.should eq 200
      moved = Model::Authority.find!(f.acadian.authority.id.as(String))
      moved.organisation_id.should eq f.ucla.organisation.id
      moved.config.to_json.should eq original_config
      moved.domain.should eq f.acadian.authority.domain
      Model::User.find!(f.acadian.user.id.as(String)).authority_id.should eq moved.id
      Model::Zone.find!(f.acadian.org_zone.id.as(String)).organisation_id.should eq f.ucla.organisation.id
      Model::ControlSystem.find!(f.acadian.system.id.as(String)).organisation_id.should eq f.ucla.organisation.id
      Model::Module.find!(f.acadian.mod.id.as(String)).organisation_id.should eq f.ucla.organisation.id
    end

    it "blocks moving a customer domain into management staff" do
      f = fixture = Spec::Tenancy.build
      operations = [{kind: "move_domain", resource_type: "authority", resource_ids: [f.acadian.authority.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.placeos.organisation.id}]
      preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      JSON.parse(preview.body)["blockers"].as_a.should_not be_empty
      Model::Authority.find!(f.acadian.authority.id.as(String)).organisation_id.should eq f.acadian.organisation.id
    end

    it "merges ownership while retaining both organisations' configuration and exact grant expiry" do
      f = fixture = Spec::Tenancy.build
      f.acadian.organisation.config = {"label" => JSON::Any.new("source")}
      f.acadian.organisation.save!
      f.ucla.organisation.config = {"label" => JSON::Any.new("target")}
      f.ucla.organisation.save!
      grant = Model::Generator.grant(f.ntt_staff.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read, expires_at: 2.hours.from_now).save!
      expiry = grant.expires_at
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "merge_organisations", source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["blockers"].as_a.should be_empty
      client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: plan["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json).status_code.should eq 200
      Model::Authority.find!(f.acadian.authority.id.as(String)).organisation_id.should eq f.ucla.organisation.id
      Model::Organisation.find!(f.acadian.organisation.id.not_nil!).config["label"].as_s.should eq "source"
      Model::Organisation.find!(f.ucla.organisation.id.not_nil!).config["label"].as_s.should eq "target"
      updated = Model::Grant.find!(grant.id.not_nil!)
      updated.scope_id.should eq f.ucla.organisation.id.to_s
      updated.permission_flags.should eq Model::Permissions::Read
      updated.expires_at.should eq expiry
    end

    it "does not widen or combine colliding grants during an organisation merge" do
      f = fixture = Spec::Tenancy.build
      Model::Generator.grant(f.ntt_staff.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read, expires_at: 1.hour.from_now).save!
      Model::Generator.grant(f.ntt_staff.admin, "organisation", f.ucla.organisation.id.to_s, Model::Permissions::Operate, expires_at: 2.hours.from_now).save!
      operations = [{kind: "merge_organisations", source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      JSON.parse(preview.body)["blockers"].as_a.should_not be_empty
      Model::Grant.where(user_id: f.ntt_staff.admin.id).count.should eq 2
    end

    it "blocks zone moves that leave domain-owned assets or group anchors behind" do
      f = fixture = Spec::Tenancy.build
      zone = Model::Generator.zone.tap(&.organisation_id = f.acadian.organisation.id).save!
      category = Model::Generator.asset_category(f.acadian.authority).save!
      type = Model::Generator.asset_type(category).save!
      asset = Model::Asset.new(asset_type_id: type.id, zone_id: zone.id).save!
      group = Model::Generator.group(authority: f.acadian.authority).save!
      anchor = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!
      operations = [{kind: "reassign", resource_type: "zone", resource_ids: [zone.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      headers = Spec::Tenancy.headers(f.placeos.admin)
      begin
        preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
        preview.status_code.should eq 200
        JSON.parse(preview.body)["blockers"].as_a.should_not be_empty
        anchor.destroy
        group.destroy
        preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
        preview.status_code.should eq 200
        JSON.parse(preview.body)["blockers"].as_a.should_not be_empty
        Model::Zone.find!(zone.id.as(String)).organisation_id.should eq f.acadian.organisation.id
      ensure
        asset.destroy
        type.destroy
        category.destroy
      end
    end

    it "intersects read-only key scopes with inventory, preview and apply" do
      f = fixture = Spec::Tenancy.build
      key = Model::ApiKey.new(name: "Reconciliation read #{random_name}", permissions: Model::UserJWT::Permissions::Admin,
        scopes: [Model::UserJWT::Scope.new("reconciliation", Model::UserJWT::Scope::Access::Read)])
      key.user = f.placeos.admin
      key.save!
      headers = HTTP::Headers{"Host" => f.placeos.authority.domain, "Content-Type" => "application/json", "X-API-Key" => key.x_api_key.not_nil!}
      client.get(base, headers: headers).status_code.should eq 200
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: JSON.parse(preview.body)["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json).status_code.should eq 403
    end
  end
end
