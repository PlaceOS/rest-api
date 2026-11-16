require "./helper"

module PlaceOS::Api
  private def self.mcp_watch_drain(events : Channel(Nil))
    loop do
      select
      when events.receive
      when timeout(100.milliseconds)
        break
      end
    end
  end

  private def self.mcp_watch_update(events : Channel(Nil), storage : Driver::RedisStorage, value : Int32)
    storage["authorisation_probe"] = value
    select
    when events.receive
    when timeout(2.seconds)
      fail "an authorised MCP watcher did not receive a state change"
    end
    mcp_watch_drain(events)
  end

  describe "live MCP resource authorisation" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    stop_watch = nil.as(Proc(Nil)?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      stop_watch.try(&.call)
      stop_watch = nil
      Utils::Tenancy.enforce = false
      if cleanup = fixture
        Spec::Tenancy.teardown(cleanup)
        fixture = nil
      end
    end

    {false, true}.each do |system_resource|
      it "rechecks a revoked grant before #{system_resource ? "system-slot" : "module"} resource notifications" do
        f = fixture = Spec::Tenancy.build
        grant = Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
        wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
        variables = {"id" => f.acadian.mod.id.as(String), "key" => "authorisation_probe", "organisation_id" => f.acadian.organisation.id.to_s}
        template = "placeos://modules/{id}/state/{key}{?organisation_id}"
        if system_resource
          variables["sys_id"] = f.acadian.system.id.as(String)
          variables["module_slug"] = f.acadian.mod.resolved_name
          template = "placeos://systems/{sys_id}/{module_slug}/{key}{?organisation_id}"
        end
        events = Channel(Nil).new(32)
        request = HTTP::Request.new("POST", MCP::PATH, Spec::Tenancy.headers(f.ucla.admin))
        stop_watch = ActionController::MCPServer.watchers[template].call(variables, request, -> { events.send(nil) })
        mcp_watch_drain(events)
        storage = Driver::RedisStorage.new(f.acadian.mod.id.as(String))
        mcp_watch_update(events, storage, 1)
        grant.destroy
        storage["authorisation_probe"] = 2
        select
        when events.receive
          fail "a revoked grant still received an MCP resource notification"
        when timeout(250.milliseconds)
        end
      end
    end

    it "rechecks a revoked key before notifying an existing module subscription" do
      f = fixture = Spec::Tenancy.build
      key = Model::ApiKey.new(name: "MCP subscription #{random_name}", permissions: Model::UserJWT::Permissions::Admin)
      key.user = f.acadian.admin
      key.save!
      headers = HTTP::Headers{"Host" => f.acadian.authority.domain, "X-API-Key" => key.x_api_key.not_nil!}
      variables = {"id" => f.acadian.mod.id.as(String), "key" => "authorisation_probe", "organisation_id" => f.acadian.organisation.id.to_s}
      events = Channel(Nil).new(32)
      request = HTTP::Request.new("POST", MCP::PATH, headers)
      stop_watch = ActionController::MCPServer.watchers["placeos://modules/{id}/state/{key}{?organisation_id}"].call(variables, request, -> { events.send(nil) })
      mcp_watch_drain(events)
      storage = Driver::RedisStorage.new(f.acadian.mod.id.as(String))
      mcp_watch_update(events, storage, 1)
      key.destroy
      storage["authorisation_probe"] = 2
      select
      when events.receive
        fail "a revoked key still received an MCP resource notification"
      when timeout(250.milliseconds)
      end
    end

    it "does not follow a system slot into another organisation after subscription" do
      f = fixture = Spec::Tenancy.build
      wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
      variables = {"sys_id" => f.acadian.system.id.as(String), "module_slug" => f.acadian.mod.resolved_name, "key" => "authorisation_probe", "organisation_id" => f.acadian.organisation.id.to_s}
      events = Channel(Nil).new(32)
      request = HTTP::Request.new("POST", MCP::PATH, Spec::Tenancy.headers(f.acadian.admin))
      stop_watch = ActionController::MCPServer.watchers["placeos://systems/{sys_id}/{module_slug}/{key}{?organisation_id}"].call(variables, request, -> { events.send(nil) })
      mcp_watch_drain(events)
      mcp_watch_update(events, Driver::RedisStorage.new(f.acadian.mod.id.as(String)), 1)
      Driver::RedisStorage.new(f.acadian.system.id.as(String), "system")["#{f.acadian.mod.resolved_name}/1"] = f.ucla.mod.id.as(String)
      mcp_watch_drain(events)
      Driver::RedisStorage.new(f.ucla.mod.id.as(String))["authorisation_probe"] = 2
      select
      when events.receive
        fail "an MCP system slot notified about a foreign runtime module"
      when timeout(250.milliseconds)
      end
    end
  end
end
