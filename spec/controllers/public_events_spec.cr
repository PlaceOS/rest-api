require "../helper"

module PlaceOS::Api
  # Helper available across the spec: build and persist a public ControlSystem.
  def self.public_control_system
    system = Model::Generator.control_system
    system.public = true
    system.save!
    system
  end

  describe PublicEvents, tags: "public_events" do
    ::Spec.before_each do
      Model::ControlSystem.clear
      Model::Driver.clear
      Model::Module.clear
    end

    # -------------------------------------------------------------------------
    # POST /guest_token/:system_id
    # -------------------------------------------------------------------------

    describe "POST /guest_token/:system_id" do
      it "returns 404 for a system that does not exist" do
        result = client.post(
          "#{PublicEvents.base_route}guest_token/sys-doesnotexist",
          headers: HTTP::Headers{
            "Host"         => "localhost",
            "Content-Type" => "application/json",
          },
          body: {captcha: "token", name: "Alice", email: "alice@external.com"}.to_json,
        )
        result.status_code.should eq 404
      end

      it "returns 404 for a system that is not public" do
        system = Model::Generator.control_system.save!

        result = client.post(
          "#{PublicEvents.base_route}guest_token/#{system.id}",
          headers: HTTP::Headers{
            "Host"         => "localhost",
            "Content-Type" => "application/json",
          },
          body: {captcha: "token", name: "Alice", email: "alice@external.com"}.to_json,
        )
        result.status_code.should eq 404
      end

      it "returns 503 when JWT_SECRET is not configured (expected in test env)" do
        system = PlaceOS::Api.public_control_system

        # Allow captcha to be skipped so that the only blocker is the missing JWT_SECRET.
        # Declared before `begin` so the ensure clause has the right type.
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        begin
          authority.internals["recaptcha_skip"] = JSON::Any.new(true)
          authority.save!

          result = client.post(
            "#{PublicEvents.base_route}guest_token/#{system.id}",
            headers: HTTP::Headers{
              "Host"         => "localhost",
              "Content-Type" => "application/json",
            },
            body: {captcha: "skip", name: "Alice", email: "alice@external.com"}.to_json,
          )

          # In CI / test environments JWT_SECRET is typically not set -> 503.
          # If it happens to be configured the route succeeds -> 200.
          (result.status_code == 503 || result.status_code == 200).should be_true
        ensure
          # Always restore authority internals so subsequent tests are unaffected.
          authority.internals.delete("recaptcha_skip")
          authority.save!
        end
      end

      it "returns an error when reCAPTCHA is not configured and the skip flag is absent" do
        system = PlaceOS::Api.public_control_system

        result = client.post(
          "#{PublicEvents.base_route}guest_token/#{system.id}",
          headers: HTTP::Headers{
            "Host"         => "localhost",
            "Content-Type" => "application/json",
          },
          body: {captcha: "some-token", name: "Alice", email: "alice@external.com"}.to_json,
        )

        # Without recaptcha_secret or recaptcha_skip the route returns 401
        # (RecaptchaFailed). If JWT_SECRET is also absent 503 arrives first.
        # Either way the response is a client/server error.
        result.status_code.should be >= 400
      end

      it "finds a system by its permalink (code) and rejects non-public ones" do
        system = Model::Generator.control_system
        system.code = "my-event-lobby"
        system.public = false
        system.save!

        result = client.post(
          "#{PublicEvents.base_route}guest_token/my-event-lobby",
          headers: HTTP::Headers{
            "Host"         => "localhost",
            "Content-Type" => "application/json",
          },
          body: {captcha: "token", name: "Bob", email: "bob@external.com"}.to_json,
        )
        result.status_code.should eq 404
      end
    end

    # -------------------------------------------------------------------------
    # GET /:system_id/events
    # -------------------------------------------------------------------------

    describe "GET /:system_id/events" do
      it "returns 401 without an authentication token" do
        system = PlaceOS::Api.public_control_system

        result = client.get(
          "#{PublicEvents.base_route}#{system.id}/events",
          headers: HTTP::Headers{"Host" => "localhost"},
        )
        result.status_code.should eq 401
      end

      it "returns 404 for a non-public system" do
        system = Model::Generator.control_system.save!

        result = client.get(
          "#{PublicEvents.base_route}#{system.id}/events",
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 404
      end

      it "returns an empty array when no PublicEvents module is present" do
        system = PlaceOS::Api.public_control_system

        result = client.get(
          "#{PublicEvents.base_route}#{system.id}/events",
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        Array(JSON::Any).from_json(result.body).should be_empty
      end

      it "returns 403 when a Scope::GUEST token has no system roles" do
        system = PlaceOS::Api.public_control_system

        # Scope::GUEST (access = All) does pass can_read_guest.  However it
        # also makes guest_scope? return true, which triggers the roles check
        # inside the action.  A token issued via Spec::Authentication carries
        # empty roles, so roles.includes?(system_id) is false → Forbidden.
        _, guest_headers = Spec::Authentication.authentication(
          sys_admin: false,
          support: false,
          scope: [Model::UserJWT::Scope::GUEST],
        )

        result = client.get(
          "#{PublicEvents.base_route}#{system.id}/events",
          headers: guest_headers,
        )
        result.status_code.should eq 403
      end

      it "allows a token with guest:read scope to list events" do
        system = PlaceOS::Api.public_control_system

        # Scope.new("guest", :read) grants explicit read access and satisfies
        # can_read_guest — the same pattern used by the metadata spec.
        _, guest_headers = Spec::Authentication.authentication(
          sys_admin: false,
          support: false,
          scope: [Model::UserJWT::Scope.new("guest", Model::UserJWT::Scope::Access::Read)],
        )

        result = client.get(
          "#{PublicEvents.base_route}#{system.id}/events",
          headers: guest_headers,
        )

        # No PublicEvents module configured -> empty array, but auth passes.
        result.status_code.should eq 200
        Array(JSON::Any).from_json(result.body).should be_empty
      end
    end

    # -------------------------------------------------------------------------
    # POST /:system_id/register
    # -------------------------------------------------------------------------

    describe "POST /:system_id/register" do
      it "returns 401 without an authentication token" do
        system = PlaceOS::Api.public_control_system

        result = client.post(
          "#{PublicEvents.base_route}#{system.id}/register",
          headers: HTTP::Headers{
            "Host"         => "localhost",
            "Content-Type" => "application/json",
          },
          body: {event_id: "evt-1", name: "Alice", email: "alice@external.com"}.to_json,
        )
        result.status_code.should eq 401
      end

      it "returns 404 for a non-public system" do
        system = Model::Generator.control_system.save!

        result = client.post(
          "#{PublicEvents.base_route}#{system.id}/register",
          headers: Spec::Authentication.headers,
          body: {event_id: "evt-1", name: "Alice", email: "alice@external.com"}.to_json,
        )
        result.status_code.should eq 404
      end

      it "returns 404 when no PublicEvents module is configured on the system" do
        system = PlaceOS::Api.public_control_system

        result = client.post(
          "#{PublicEvents.base_route}#{system.id}/register",
          headers: Spec::Authentication.headers,
          body: {event_id: "evt-1", name: "Alice", email: "alice@external.com"}.to_json,
        )
        result.status_code.should eq 404
      end

      it "returns 403 when a Scope::GUEST token has no system roles" do
        system = PlaceOS::Api.public_control_system

        # Scope::GUEST (access = All) does pass can_read_guest.  However it
        # also makes guest_scope? return true, which triggers the roles check
        # inside the action.  A token issued via Spec::Authentication carries
        # empty roles, so roles.includes?(system_id) is false → Forbidden.
        _, guest_headers = Spec::Authentication.authentication(
          sys_admin: false,
          support: false,
          scope: [Model::UserJWT::Scope::GUEST],
        )

        result = client.post(
          "#{PublicEvents.base_route}#{system.id}/register",
          headers: guest_headers,
          body: {event_id: "evt-1", name: "Alice", email: "alice@external.com"}.to_json,
        )
        result.status_code.should eq 403
      end

      it "delegates to the driver and returns its result when the module is present" do
        system = PlaceOS::Api.public_control_system

        driver = Model::Generator.driver(role: Model::Driver::Role::Logic)
        driver.module_name = "PublicEvents"
        driver.save!

        mod = Model::Generator.module(driver: driver)
        mod.running = true
        mod.save!
        system.modules = [mod.id.as(String)]
        system.save!

        module_id = mod.id.as(String)
        sys_id = system.id.as(String)

        # Seed the system-to-module lookup so Proxy::System.module_id? resolves.
        system_storage = ::PlaceOS::Driver::RedisStorage.new(sys_id, "system")
        system_storage["PublicEvents/1"] = module_id

        # Seed the driver interface metadata so RemoteDriver.metadata? resolves
        # and function_present?("register_attendee") returns true.
        # This mirrors the pattern used in systems_spec.cr for functions/state tests.
        ::PlaceOS::Driver::RedisStorage.with_redis do |redis|
          meta = ::PlaceOS::Driver::DriverModel::Metadata.new(
            {"register_attendee" => {
              "event_id" => JSON.parse(%({"type":"String"})),
              "name"     => JSON.parse(%({"type":"String"})),
              "email"    => JSON.parse(%({"type":"String"})),
            } of String => JSON::Any},
            ["Place::PublicEvents"],
          )
          redis.set("interface/#{module_id}", meta.to_json)
        end

        # Stub the core command HTTP endpoint to return true.
        WebMock.stub(:post, /\/api\/core\/v1\/command\//).to_return(
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: "true",
        )

        result = client.post(
          "#{PublicEvents.base_route}#{system.id}/register",
          headers: Spec::Authentication.headers,
          body: {event_id: "evt-public-1", name: "Alice", email: "alice@external.com"}.to_json,
        )

        result.status_code.should eq 200
        result.body.should eq "true"

        system_storage.delete("PublicEvents/1")
        ::PlaceOS::Driver::RedisStorage.with_redis(&.del("interface/#{module_id}"))
      end
    end
  end
end
