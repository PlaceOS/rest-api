require "../helper"

module PlaceOS::Api::WebSocket
  private def self.scoped_socket(user : Model::User, organisation_id : UUID, scopes : Array(Model::UserJWT::Scope)? = nil, &)
    credentials = Spec::Tenancy.headers(user)
    bearer = credentials["Authorization"].split(' ').last
    if scopes
      token = Model::UserJWT.decode(bearer)
      bearer = Model::UserJWT.new(iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, user: token.user, scope: scopes).encode
    end
    path = "#{Systems.base_route}control?bearer_token=#{bearer}&organisation_id=#{organisation_id}"
    socket = client.establish_ws(path, headers: HTTP::Headers{"Host" => credentials["Host"]})
    responses = Channel(Session::Response).new(32)
    socket.on_message do |message|
      responses.send(Session::Response.from_json(message)) unless message == "pong"
    end
    spawn { socket.run }
    yield socket, responses
  ensure
    socket.try &.close
  end

  private def self.scope_response(responses : Channel(Session::Response), request_id : Int64) : Session::Response
    loop do
      select
      when response = responses.receive
        return response if response.id == request_id && !response.type.notify?
      when timeout(5.seconds)
        raise "timed out waiting for socket response #{request_id}"
      end
    end
  end

  private def self.scope_request(id : Int64, system : Model::ControlSystem, mod : String, command : Session::Request::Command, name : String = "scope_test")
    Session::Request.new(id: id, system_id: system.id.as(String), module_name: mod, command: command, name: name)
  end

  describe "organisation-scoped websocket sessions" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "keeps a selected customer separate from another reachable organisation" do
      f = fixture = Spec::Tenancy.build
      scoped_socket(f.ntt_staff.admin, f.acadian.organisation.id.as(UUID)) do |socket, responses|
        socket.send scope_request(1_i64, f.ntt_staff.system, f.ntt_staff.mod.resolved_name, :bind).to_json
        response = scope_response(responses, 1_i64)
        response.type.should eq Session::Response::Type::Error
        response.error_code.should eq Session::Response::ErrorCode::ModuleNotFound
      end
    end

    it "refuses a foreign module id paired with a system in the selected organisation" do
      f = fixture = Spec::Tenancy.build
      scoped_socket(f.ntt_staff.admin, f.acadian.organisation.id.as(UUID)) do |socket, responses|
        socket.send scope_request(2_i64, f.acadian.system, f.ntt_staff.mod.id.as(String), :debug).to_json
        response = scope_response(responses, 2_i64)
        response.type.should eq Session::Response::Type::Error
        response.error_code.should eq Session::Response::ErrorCode::AccessDenied
      end
    end

    it "does not expose a foreign module referenced by a selected system" do
      f = fixture = Spec::Tenancy.build
      f.acadian.system.modules = [f.ntt_staff.mod.id.as(String)]
      f.acadian.system.save!
      scoped_socket(f.ntt_staff.admin, f.acadian.organisation.id.as(UUID)) do |socket, responses|
        socket.send scope_request(9_i64, f.acadian.system, f.ntt_staff.mod.resolved_name, :bind).to_json
        response = scope_response(responses, 9_i64)
        response.type.should eq Session::Response::Type::Error
        response.error_code.should eq Session::Response::ErrorCode::ModuleNotFound

        f.acadian.system.modules = [f.acadian.mod.id.as(String)]
        f.acadian.system.save!
        wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
        PgORM::Database.connection do |db|
          db.exec("UPDATE mod SET control_system_id = $1 WHERE id = $2", args: [f.ntt_staff.system.id.as(String), f.acadian.mod.id.as(String)])
        end
        socket.send scope_request(10_i64, f.acadian.system, f.acadian.mod.resolved_name, :exec).to_json
        scope_response(responses, 10_i64).error_code.should eq Session::Response::ErrorCode::ModuleNotFound
      end
    end

    it "rechecks grants on an already open socket" do
      f = fixture = Spec::Tenancy.build
      grant = Model::Grant.new(user_id: f.ucla.admin.id.as(String), scope_type: "organisation", scope_id: f.acadian.organisation.id.to_s, permissions: Model::Permissions::Read.to_i).save!
      wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
      scoped_socket(f.ucla.admin, f.acadian.organisation.id.as(UUID)) do |socket, responses|
        socket.send scope_request(3_i64, f.acadian.system, f.acadian.mod.resolved_name, :bind).to_json
        scope_response(responses, 3_i64).type.should eq Session::Response::Type::Success
        grant.destroy
        socket.send scope_request(4_i64, f.acadian.system, f.acadian.mod.resolved_name, :bind, "after_revoke").to_json
        response = scope_response(responses, 4_i64)
        response.type.should eq Session::Response::Type::Error
        response.error_code.should eq Session::Response::ErrorCode::AccessDenied
      end
    end

    it "allows read-only OAuth scopes to bind while refusing execution on the same socket" do
      f = fixture = Spec::Tenancy.build
      scopes = [Model::UserJWT::Scope.new("control", Model::UserJWT::Scope::Access::Read)]
      wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
      scoped_socket(f.acadian.admin, f.acadian.organisation.id.as(UUID), scopes) do |socket, responses|
        socket.send scope_request(6_i64, f.acadian.system, f.acadian.mod.resolved_name, :bind).to_json
        scope_response(responses, 6_i64).type.should eq Session::Response::Type::Success
        socket.send scope_request(7_i64, f.acadian.system, f.acadian.mod.resolved_name, :exec).to_json
        response = scope_response(responses, 7_i64)
        response.error_code.should eq Session::Response::ErrorCode::AccessDenied
        response.response_code.should eq 403
      end
    end

    it "stops an existing subscription from delivering state after its grant is revoked" do
      f = fixture = Spec::Tenancy.build
      grant = Model::Grant.new(user_id: f.ucla.admin.id.as(String), scope_type: "organisation", scope_id: f.acadian.organisation.id.to_s, permissions: Model::Permissions::Read.to_i).save!
      wait_for_module_lookups(f.acadian.system.id.as(String), {"#{f.acadian.mod.resolved_name}/1" => f.acadian.mod.id.as(String)})
      scoped_socket(f.ucla.admin, f.acadian.organisation.id.as(UUID)) do |socket, responses|
        socket.send scope_request(8_i64, f.acadian.system, f.acadian.mod.resolved_name, :bind, "live_scope").to_json
        scope_response(responses, 8_i64).type.should eq Session::Response::Type::Success
        storage = PlaceOS::Driver::RedisStorage.new(f.acadian.mod.id.as(String))
        storage["live_scope"] = 100
        loop do
          select
          when response = responses.receive
            break if response.type.notify? && response.value == "100"
          when timeout(5.seconds)
            raise "initial authorised state notification was not delivered"
          end
        end
        grant.destroy
        storage["live_scope"] = 200
        deadline = Time.instant + 500.milliseconds
        loop do
          remaining = deadline - Time.instant
          break if remaining <= Time::Span.zero
          select
          when response = responses.receive
            response.value.should_not eq "200"
          when timeout(remaining)
            break
          end
        end
      end
    end

    it "does not ignore a revoked API key because its scope includes guest" do
      f = fixture = Spec::Tenancy.build
      key = Model::ApiKey.new(name: "Guest-marked key #{random_name}", scopes: [Model::UserJWT::Scope::PUBLIC, Model::UserJWT::Scope::GUEST])
      key.user = f.acadian.admin
      key.save!
      policy = Utils::Tenancy::Policy.new(key.build_jwt, f.acadian.authority.id.as(String), f.acadian.organisation.id, key.id.as(String))
      policy.system_access?(f.acadian.system.id.as(String), Model::Permissions::Read).should be_true
      key.destroy
      policy.system_access?(f.acadian.system.id.as(String), Model::Permissions::Read).should be_false
    end

    it "uses an API key's real lifetime rather than its synthetic JWT expiry" do
      f = fixture = Spec::Tenancy.build
      key = Model::ApiKey.new(name: "Persistent key #{random_name}")
      key.user = f.acadian.admin
      key.save!
      original = key.build_jwt
      token = Model::UserJWT.new(iss: original.iss, iat: original.iat, exp: 1.second.ago, domain: original.domain, id: original.id, user: original.user, scope: original.scope)
      policy = Utils::Tenancy::Policy.new(token, f.acadian.authority.id.as(String), f.acadian.organisation.id, key.id.as(String))
      policy.system_access?(f.acadian.system.id.as(String), Model::Permissions::Read).should be_true
      key.destroy
      policy.system_access?(f.acadian.system.id.as(String), Model::Permissions::Read).should be_false
    end

    it "does not turn a read grant into execution through the caller's home admin flag" do
      f = fixture = Spec::Tenancy.build
      Model::Grant.new(user_id: f.ucla.admin.id.as(String), scope_type: "organisation", scope_id: f.acadian.organisation.id.to_s, permissions: Model::Permissions::Read.to_i).save!
      scoped_socket(f.ucla.admin, f.acadian.organisation.id.as(UUID)) do |socket, responses|
        socket.send scope_request(5_i64, f.acadian.system, f.acadian.mod.resolved_name, :exec, "scope_test").to_json
        response = scope_response(responses, 5_i64)
        response.type.should eq Session::Response::Type::Error
        response.error_code.should eq Session::Response::ErrorCode::AccessDenied
        response.response_code.should eq 403
      end
    end
  end
end
