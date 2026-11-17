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
      f.unowned_system.modules = [mod.id.as(String)]
      f.unowned_system.save!
      Model::ControlSystem.find!(f.unowned_system.id.as(String)).modules.should contain(mod.id)
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
      responses = Channel(HTTP::Client::Response).new(2)
      2.times do
        spawn { responses.send(ActionController::SpecHelper.client.post("#{base}/apply", headers: headers, body: body)) }
      end
      applied = responses.receive
      duplicate = responses.receive
      applied.status_code.should eq 200
      duplicate.status_code.should eq 200
      JSON.parse(duplicate.body).should eq JSON.parse(applied.body)
      Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should eq f.acadian.organisation.id
      Model::ControlSystem.find!(f.unowned_system.id.as(String)).organisation_id.should eq f.acadian.organisation.id
      replay = client.post("#{base}/apply", headers: headers, body: body)
      replay.status_code.should eq 200
      JSON.parse(replay.body).should eq JSON.parse(applied.body)
      receipt = client.get("#{base}/#{JSON.parse(applied.body)["id"].as_s}", headers: headers)
      receipt.status_code.should eq 200
      JSON.parse(receipt.body)["actor_id"].as_s.should eq f.placeos.admin.id
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
      original_config = JSON.parse(f.acadian.authority.config.to_json)
      operations = [{kind: "move_domain", resource_type: "authority", resource_ids: [f.acadian.authority.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["blockers"].as_a.should be_empty
      client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: plan["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json).status_code.should eq 200
      moved = Model::Authority.find!(f.acadian.authority.id.as(String))
      moved.organisation_id.should eq f.ucla.organisation.id
      JSON.parse(moved.config.to_json).should eq original_config
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
      expiry = Model::Grant.find!(grant.id.not_nil!).expires_at
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
    it "blocks modules on foreign edges" do
      f = fixture = Spec::Tenancy.build
      edge = Model::Generator.edge(f.ucla.user).tap(&.organisation_id = f.ucla.organisation.id).save!
      driver = Model::Generator.driver(role: Model::Driver::Role::Device).save!
      mod = Model::Generator.module(driver: driver).tap(&.edge_id = edge.id).save!
      f.unowned_system.modules = [mod.id.as(String)]
      f.unowned_system.save!
      Model::ControlSystem.find!(f.unowned_system.id.as(String)).modules.should contain(mod.id)
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("reference_owner")
    ensure
      mod.try(&.destroy)
      edge.try(&.destroy)
    end

    it "checks incoming modules when claiming an edge" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.placeos.admin)
      edge = Model::Generator.edge(f.acadian.user).save!
      driver = Model::Generator.driver(role: Model::Driver::Role::Device).save!
      incoming = Model::Generator.module(driver: driver).tap do |mod|
        mod.organisation_id = f.ucla.organisation.id
        mod.edge_id = edge.id
      end.save!
      f.ucla.system.modules = f.ucla.system.modules + [incoming.id.as(String)]
      f.ucla.system.save!
      Model::ControlSystem.find!(f.ucla.system.id.as(String)).modules.should contain(incoming.id)
      begin
        operations = [{kind: "claim", resource_type: "edge", resource_ids: [edge.id], target_organisation_id: f.acadian.organisation.id}]
        preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
        JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("reference_owner")
      ensure
        f.ucla.system.modules = f.ucla.system.modules.reject { |id| id == incoming.id }
        f.ucla.system.save!
        incoming.destroy
        edge.destroy
      end
    end

    it "blocks system moves that strand trigger-instance zone references" do
      f = fixture = Spec::Tenancy.build
      system = Model::Generator.control_system.tap(&.organisation_id = f.acadian.organisation.id).save!
      trigger = Model::Generator.trigger(system).tap(&.organisation_id = f.acadian.organisation.id).save!
      instance = Model::Generator.trigger_instance(trigger, f.acadian.org_zone, system).save!
      begin
        operations = [{kind: "reassign", resource_type: "sys", resource_ids: [system.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
        preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
        preview.status_code.should eq 200
        JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("reference_owner")
      ensure
        instance.destroy
      end
    end

    it "checks incoming trigger instances when a trigger definition moves" do
      f = fixture = Spec::Tenancy.build
      trigger = Model::Generator.trigger.tap(&.organisation_id = f.acadian.organisation.id).save!
      instance = Model::Generator.trigger_instance(trigger, f.acadian.org_zone, f.acadian.system).save!
      begin
        operations = [{kind: "reassign", resource_type: "trigger", resource_ids: [trigger.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
        preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
        JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("reference_owner")
      ensure
        instance.destroy
      end
    end

    it "checks a trigger instance's definition when its zone moves" do
      f = fixture = Spec::Tenancy.build
      trigger = Model::Generator.trigger(f.ucla.system).tap(&.organisation_id = f.ucla.organisation.id).save!
      instance = Model::Generator.trigger_instance(trigger, f.unowned_zone, f.acadian.system).save!
      begin
        operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
        preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
        JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("reference_owner")
      ensure
        instance.destroy
      end
    end

    it "blocks ambiguous merge chains" do
      f = fixture = Spec::Tenancy.build
      target = Model::Generator.organisation.save!
      operations = [
        {kind: "merge_organisations", source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id},
        {kind: "merge_organisations", source_organisation_id: f.ucla.organisation.id, target_organisation_id: target.id},
      ]
      headers = Spec::Tenancy.headers(f.placeos.admin)
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("merge_overlap")
    end

    it "detects grants colliding across two merge sources" do
      f = fixture = Spec::Tenancy.build
      target = Model::Generator.organisation.save!
      headers = Spec::Tenancy.headers(f.placeos.admin)
      Model::Generator.grant(f.ntt_staff.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      Model::Generator.grant(f.ntt_staff.admin, "organisation", f.ucla.organisation.id.to_s, Model::Permissions::Operate).save!
      operations = [
        {kind: "merge_organisations", source_organisation_id: f.acadian.organisation.id, target_organisation_id: target.id},
        {kind: "merge_organisations", source_organisation_id: f.ucla.organisation.id, target_organisation_id: target.id},
      ]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("grant_collision")
    end

    it "bounds referrer snapshots even when a plan changes only one tree" do
      f = fixture = Spec::Tenancy.build
      PgORM::Database.connection do |db|
        db.exec(<<-SQL, args: [f.acadian.authority.id.as(String), f.acadian.user.id.as(String), f.unowned_zone.id.as(String)])
          INSERT INTO pending_mail (id, authority_id, user_id, zones, created_at, updated_at)
          SELECT uuidv7(), $1, $2, ARRAY[$3]::text[], now(), now() FROM generate_series(1, 5001)
          SQL
      end
      begin
        operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.acadian.organisation.id}]
        preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
        preview.status_code.should eq 400
        preview.body.should contain("plan_too_large")
      ensure
        PgORM::Database.connection(&.exec("DELETE FROM pending_mail WHERE authority_id = $1", args: [f.acadian.authority.id.as(String)]))
      end
    end

    it "keeps edge heartbeats out of the reviewed security fingerprint" do
      f = fixture = Spec::Tenancy.build
      edge = Model::Generator.edge(f.acadian.user).save!
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "claim", resource_type: "edge", resource_ids: [edge.id], target_organisation_id: f.acadian.organisation.id}]
      begin
        preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
        JSON.parse(preview.body)["blockers"].as_a.should be_empty
        edge.online = !edge.online
        edge.last_seen = Time.utc
        edge.save!
        response = client.post("#{base}/apply", headers: headers,
          body: {operations: operations, digest: JSON.parse(preview.body)["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json)
        response.status_code.should eq 200
      ensure
        edge.destroy
      end
    end

    it "holds referrer membership stable during apply" do
      f = fixture = Spec::Tenancy.build
      group = Model::Generator.group(authority: f.ucla.authority).save!
      operations = [Utils::Reconciliation::Operation.new("claim", "zone", [f.unowned_zone.id.as(String)], target_organisation_id: f.acadian.organisation.id)]
      preview = Utils::Reconciliation.preview(operations)
      calls = 0
      begin
        Utils::Reconciliation.apply(operations, preview.digest, UUID.random.to_s, f.placeos.admin.id.as(String), f.placeos.authority.id.as(String), nil) do
          calls += 1
          if calls == 2
            blocked = Channel(Bool).new(1)
            spawn do
              PgORM::Database.transaction do |tx|
                tx.connection.exec("SET LOCAL lock_timeout = '150ms'", args: [] of String)
                tx.connection.exec(<<-SQL, args: [group.id.to_s, f.unowned_zone.id.as(String)])
                  INSERT INTO group_zones (group_id, zone_id, created_at, updated_at)
                  VALUES ($1::uuid, $2, now(), now())
                  SQL
              end
              blocked.send(false)
            rescue error : PQ::PQError
              blocked.send(error.field_message(:code) == "55P03")
            rescue
              blocked.send(false)
            end
            blocked.receive.should be_true
          end
          nil
        end
      ensure
        group.destroy
      end
    end

    it "rolls back ownership, history and receipts on a real late SQL failure" do
      f = fixture = Spec::Tenancy.build
      operations = [Utils::Reconciliation::Operation.new("claim", "zone", [f.unowned_zone.id.as(String)], target_organisation_id: f.acadian.organisation.id)]
      preview = Utils::Reconciliation.preview(operations)
      history_before = Model::History.where(resource_id: [f.unowned_zone.id, f.unowned_system.id]).count
      key = UUID.random.to_s
      PgORM::Database.connection do |db|
        db.exec(<<-SQL, args: [] of String)
          CREATE FUNCTION reconciliation_receipt_failure_spec() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN RAISE EXCEPTION 'receipt insertion failed'; END; $$
          SQL
        db.exec("CREATE TRIGGER reconciliation_receipt_failure_spec BEFORE INSERT ON tenancy_reconciliations FOR EACH ROW EXECUTE FUNCTION reconciliation_receipt_failure_spec()", args: [] of String)
      end
      begin
        expect_raises(PQ::PQError, /receipt insertion failed/) do
          Utils::Reconciliation.apply(operations, preview.digest, key, f.placeos.admin.id.as(String), f.placeos.authority.id.as(String), nil) { }
        end
        Model::Zone.find!(f.unowned_zone.id.as(String)).organisation_id.should be_nil
        Model::ControlSystem.find!(f.unowned_system.id.as(String)).organisation_id.should be_nil
        Model::History.where(resource_id: [f.unowned_zone.id, f.unowned_system.id]).count.should eq history_before
        PgORM::Database.connection do |db|
          db.query_one("SELECT count(*) FROM tenancy_reconciliations WHERE idempotency_key = $1", args: [key], &.read(Int64)).should eq 0
        end
      ensure
        PgORM::Database.connection do |db|
          db.exec("DROP TRIGGER IF EXISTS reconciliation_receipt_failure_spec ON tenancy_reconciliations", args: [] of String)
          db.exec("DROP FUNCTION IF EXISTS reconciliation_receipt_failure_spec()", args: [] of String)
        end
      end
    end
    it "summarises existing destination grant reach and safe principal samples" do
      f = fixture = Spec::Tenancy.build
      Model::Generator.grant(f.ntt_staff.user, "organisation", f.ucla.organisation.id.to_s, Model::Permissions::Read).save!
      operations = [{kind: "merge_organisations", source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      plan = JSON.parse(preview.body)
      plan["target_grant_effects"]?.should_not be_nil
      effects = plan["target_grant_effects"].as_a
      effects.find! { |effect| effect["scope_id"].as_s == f.ucla.organisation.id.to_s }["grants_affected"].as_i.should eq 1
      access = plan["access_changes"].as_a.first
      access["user_sample"].as_a.map(&.as_s).should contain(f.acadian.admin.id)
      access["active_administrators"].as_i.should eq 1
      access["sample_complete"].as_bool.should be_true
      preview.body.should_not contain("password_digest")
      preview.body.should_not contain("access_token")
      operations = [{kind: "claim", resource_type: "zone", resource_ids: [f.unowned_zone.id], target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
      effects = JSON.parse(preview.body)["target_grant_effects"].as_a
      effects.find! { |effect| effect["scope_id"].as_s == f.ucla.organisation.id.to_s }["grants_affected"].as_i.should eq 1
    end

    it "blocks missing or foreign edge credentials while preserving the edge principal" do
      f = fixture = Spec::Tenancy.build
      edge = Model::Generator.edge(f.acadian.user).save!
      original_key = edge.api_key_id
      other = Model::ApiKey.new(name: "Reconciliation foreign #{random_name}")
      other.user = f.ucla.user
      other.save!
      operations = [{kind: "claim", resource_type: "edge", resource_ids: [edge.id], target_organisation_id: f.acadian.organisation.id}]
      begin
        [other.id.as(String), "missing-key-#{UUID.random}"].each do |key_id|
          PgORM::Database.connection(&.exec("UPDATE edge SET api_key_id = $1 WHERE id = $2", args: [key_id, edge.id.as(String)]))
          preview = client.post("#{base}/preview", headers: Spec::Tenancy.headers(f.placeos.admin), body: {operations: operations}.to_json)
          preview.status_code.should eq 200
          JSON.parse(preview.body)["blockers"].as_a.map(&.["code"].as_s).should contain("reference_owner")
        end
      ensure
        PgORM::Database.connection(&.exec("UPDATE edge SET api_key_id = $1 WHERE id = $2", args: [original_key, edge.id.as(String)]))
        edge.destroy
        other.destroy
      end
    end

    it "keeps ordinary user login activity out of an ownership fingerprint" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "move_domain", resource_type: "authority", resource_ids: [f.acadian.authority.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      f.acadian.user.login_count += 1
      f.acadian.user.last_login = Time.utc
      f.acadian.user.save!
      response = client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: JSON.parse(preview.body)["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json)
      response.status_code.should eq 200
    end
    it "invalidates a reviewed move when the domain login identity changes" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.placeos.admin)
      operations = [{kind: "move_domain", resource_type: "authority", resource_ids: [f.acadian.authority.id], source_organisation_id: f.acadian.organisation.id, target_organisation_id: f.ucla.organisation.id}]
      preview = client.post("#{base}/preview", headers: headers, body: {operations: operations}.to_json)
      preview.status_code.should eq 200
      f.acadian.authority.domain = "renamed-#{UUID.random}.test"
      f.acadian.authority.save!
      response = client.post("#{base}/apply", headers: headers,
        body: {operations: operations, digest: JSON.parse(preview.body)["digest"].as_s, idempotency_key: UUID.random.to_s}.to_json)
      response.status_code.should eq 409
      Model::Authority.find!(f.acadian.authority.id.as(String)).organisation_id.should eq f.acadian.organisation.id
    end
  end
end
