require "../helper"

module PlaceOS::Api
  describe "organisation runtime module references" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if cleanup = fixture
        Spec::Tenancy.teardown(cleanup)
        fixture = nil
      end
    end

    it "rejects a foreign runtime alias before reading state or executing" do
      f = fixture = Spec::Tenancy.build
      sys_id, mod_id = f.acadian.system.id.as(String), f.acadian.mod.id.as(String)
      name = f.acadian.mod.resolved_name
      wait_for_module_lookups(sys_id, {"#{name}/1" => mod_id})
      Driver::RedisStorage.new(sys_id, "system")["#{name}/1"] = f.ucla.mod.id.as(String)
      Driver::RedisStorage.new(f.ucla.mod.id.as(String))["isolation_secret"] = "123"
      headers = Spec::Tenancy.headers(f.acadian.admin)
      client.get("#{Systems.base_route}#{sys_id}/#{name}", headers: headers).status_code.should eq 404
      client.get("#{Systems.base_route}#{sys_id}/#{name}/isolation_secret", headers: headers).status_code.should eq 404
      client.post("#{Systems.base_route}#{sys_id}/#{name}/isolation_test", headers: headers, body: "[]").status_code.should eq 404
      Systems.module_state(sys_id, name, 1).should be_nil
    end

    it "does not expose a foreign module referenced directly by an owned system" do
      f = fixture = Spec::Tenancy.build
      f.acadian.system.modules = [f.ucla.mod.id.as(String)]
      f.acadian.system.save!
      name = f.ucla.mod.resolved_name
      wait_for_module_lookups(f.acadian.system.id.as(String), {"#{name}/1" => f.ucla.mod.id.as(String)})
      headers = Spec::Tenancy.headers(f.acadian.admin)
      client.get("#{Systems.base_route}#{f.acadian.system.id}/#{name}", headers: headers).status_code.should eq 404
    end

    it "leaves foreign modules unchanged when starting or stopping an owned system" do
      f = fixture = Spec::Tenancy.build
      f.ucla.mod.update_fields(running: false)
      f.acadian.system.modules = [f.acadian.mod.id.as(String), f.ucla.mod.id.as(String)]
      f.acadian.system.save!
      headers = Spec::Tenancy.headers(f.acadian.admin)
      client.post("#{Systems.base_route}#{f.acadian.system.id}/start?single_occurrence=false", headers: headers).status_code.should eq 200
      Model::Module.find!(f.ucla.mod.id.as(String)).running.should be_false
      f.ucla.mod.update_fields(running: true)
      client.post("#{Systems.base_route}#{f.acadian.system.id}/stop?single_occurrence=false", headers: headers).status_code.should eq 200
      Model::Module.find!(f.ucla.mod.id.as(String)).running.should be_true
    end

    it "rejects an owned module with a foreign parent before execution" do
      f = fixture = Spec::Tenancy.build
      PgORM::Database.connection do |db|
        db.exec("UPDATE mod SET control_system_id = $1 WHERE id = $2", args: [f.ucla.system.id.as(String), f.acadian.mod.id.as(String)])
      end
      headers = Spec::Tenancy.headers(f.acadian.admin)
      client.post("#{Modules.base_route}#{f.acadian.mod.id}/exec/isolation_test", headers: headers, body: "[]").status_code.should eq 404
    end
  end
end
