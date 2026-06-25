require "../helper"
require "timecop"

module PlaceOS::Api
  describe Modules do
    ::Spec.before_each do
      Model::Module.clear
      Model::ControlSystem.clear
    end

    Spec.test_404(Modules.base_route, model_name: Model::Module.table_name, headers: Spec::Authentication.headers)

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(klass: Model::Module, controller_klass: Modules)

      it "update preserves logic module connection status" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        mod = Model::Generator.module(driver: driver).save!

        mod.connected = false

        id = mod.id.as(String)
        path = File.join(Modules.base_route, id)

        result = client.patch(
          path: path,
          body: mod.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::Module.from_trusted_json(result.body)
        updated.id.should eq mod.id
        updated.connected.should be_true
      end

      it "update" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
        mod = Model::Generator.module(driver: driver).save!

        connected = mod.connected
        mod.connected = !connected

        id = mod.id.as(String)
        path = File.join(Modules.base_route, id)

        result = client.patch(
          path: path,
          body: mod.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::Module.from_trusted_json(result.body)
        updated.id.should eq mod.id
        updated.connected.should eq !connected
      end

      it "can update logic modules as a management user" do
        control_system = Model::Generator.control_system
        control_system.zones << Spec::Authentication.org_zone.id.as(String)
        control_system.zones_will_change!
        control_system.save!

        # ensure the user can't edit modules that are not logics
        ser_driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
        protected_mod = Model::Generator.module(driver: ser_driver).save!

        connected = protected_mod.connected
        protected_mod.connected = !connected

        id = protected_mod.id.as(String)
        path = File.join(Modules.base_route, id)

        result = client.patch(
          path: path,
          body: protected_mod.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"]),
        )
        result.status_code.should eq 403

        # ensure they can edit modules they have access to
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        mod = Model::Generator.module(driver: driver, control_system: control_system).save!

        connected = mod.connected
        mod.connected = !connected

        id = mod.id.as(String)
        path = File.join(Modules.base_route, id)

        result = client.patch(
          path: path,
          body: mod.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"]),
        )

        result.status_code.should eq 200
        updated = Model::Module.from_trusted_json(result.body)
        updated.id.should eq mod.id
      end

      it "POST endpoint should discard read-only field updates" do
        mod = PlaceOS::Model::Generator.module
        mod_json = JSON.parse(mod.to_json)
        mod_json.as_h["has_runtime_error"] = JSON::Any.new(true)
        mod_json.as_h["error_timestamp"] = JSON::Any.new(0)

        groups = [] of String
        result = client.post(Modules.base_route, body: mod_json.to_json,
          headers: Spec::Authentication.headers(sys_admin: true, support: true, groups: groups))
        result.status_code.should eq 201
        mod1 = PlaceOS::Model::Module.from_trusted_json(result.body)

        result = client.get(path: File.join(Modules.base_route, mod1.id.as(String)),
          headers: Spec::Authentication.headers)

        result.status_code.should eq 200

        mod2 = PlaceOS::Model::Module.from_json(result.body)
        mod2.has_runtime_error.should be_false
        mod2.error_timestamp.should be_nil
      end
    end

    describe "index", tags: "search" do
      it "queries by parent driver" do
        name = random_name

        driver = Model::Generator.driver
        driver.name = name
        driver.save!

        # Module name is dependent on the driver's name
        doc = Model::Generator.module(driver: driver).save!
        doc.persisted?.should be_true

        refresh_elastic(Model::Module.table_name)

        params = HTTP::Params.encode({"q" => name})
        path = "#{Modules.base_route.rstrip('/')}?#{params}"
        header = Spec::Authentication.headers
        found = until_expected("GET", path, header) do |response|
          Array(Hash(String, JSON::Any)).from_json(response.body).any? do |result|
            result["id"].as_s == doc.id
          end
        end

        found.should be_true
      end

      it "looks up by system_id" do
        mod = Model::Generator.module.save!
        sys = Model::Generator.control_system
        sys.modules = [mod.id.as(String)]
        sys.save!

        # Call the index method of the controller
        params = HTTP::Params{"control_system_id" => sys.id.as(String)}
        response = client.get(
          "#{Modules.base_route}?#{params}",
          headers: Spec::Authentication.headers,
        )

        response.status_code.should eq 200
        response.headers["X-Total-Count"].should eq("1")
        Array(Hash(String, JSON::Any)).from_json(response.body.to_s).map(&.["id"].as_s).first?.should eq(mod.id)
      end

      it "ensures management users can only see the modules they have access to" do
        # before_each clears the DB but not ES; this assertion counts the
        # unscoped index, so start from a clean ES slate to avoid stale docs
        # from earlier examples inflating the management-visible count.
        clear_elastic(Model::Module.table_name)

        Model::Generator.module.save!
        Model::Generator.module.save!
        Model::Generator.module.save!
        mod = Model::Generator.module.save!
        sys = Model::Generator.control_system
        sys.zones << Spec::Authentication.org_zone.id.as(String)
        sys.zones_will_change!
        sys.modules = [mod.id.as(String)]
        sys.save!

        refresh_elastic(Model::Module.table_name)

        # ensure regular users can't use the route
        params = HTTP::Params{"control_system_id" => sys.id.as(String)}
        response = client.get(
          "#{Modules.base_route}?#{params}",
          headers: Spec::Authentication.headers(sys_admin: false, support: false),
        )
        response.status_code.should eq 403

        # management users can see the list of modules in a control system
        params = HTTP::Params{"control_system_id" => sys.id.as(String)}
        response = client.get(
          "#{Modules.base_route}?#{params}",
          headers: Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"]),
        )
        response.status_code.should eq 200

        # Admins can see everything
        header = Spec::Authentication.headers
        until_expected("GET", Modules.base_route, header) do |resp|
          response = resp
          resp.success? ? (resp.headers["X-Total-Count"].to_i > 1) : false
        end
        response.status_code.should eq 200
        response.headers["X-Total-Count"].to_i > 1

        # Management can only see the one
        header = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])
        until_expected("GET", Modules.base_route, header) do |resp|
          response = resp
          resp.success? ? (resp.headers["X-Total-Count"].to_i > 0) : false
        end

        # check the results
        response.status_code.should eq 200
        response.headers["X-Total-Count"].should eq("1")
        Array(Hash(String, JSON::Any)).from_json(response.body.to_s).map(&.["id"].as_s).first?.should eq(mod.id)
      end

      context "query parameter" do
        it "as_of" do
          mod1 = Model::Generator.module
          mod1.connected = true
          Timecop.freeze(2.days.ago) do
            mod1.save!
          end
          mod1.persisted?.should be_true

          mod2 = Model::Generator.module
          mod2.connected = true
          mod2.save!
          mod2.persisted?.should be_true

          params = HTTP::Params.encode({"as_of" => (mod1.updated_at.try &.to_unix).to_s})
          path = "#{Modules.base_route}?#{params}"

          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            contains_correct = results.any?(mod1.id)
            contains_incorrect = results.any?(mod2.id)
            !results.empty? && contains_correct && !contains_incorrect
          end

          found.should be_true
        end

        it "no_logic" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
          mod = Model::Generator.module(driver: driver)
          mod.role = Model::Driver::Role::Service
          mod.save!

          params = HTTP::Params.encode({"no_logic" => "true"})
          path = "#{Modules.base_route}?#{params}"

          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body)

            no_logic = results.all? { |r| r["role"].as_i != Model::Driver::Role::Logic.to_i }
            contains_created = results.any? { |r| r["id"].as_s == mod.id }

            !results.empty? && no_logic && contains_created
          end

          found.should be_true
        end
      end

      it "only returns matches" do
        name_one = random_name
        driver_one = Model::Generator.driver
        driver_one.name = name_one
        driver_one.save!
        doc_one = Model::Generator.module(driver: driver_one).save!
        doc_one.persisted?.should be_true

        name_two = random_name
        driver_two = Model::Generator.driver
        driver_two.name = name_two
        driver_two.save!
        doc_two = Model::Generator.module(driver: driver_two).save!
        doc_two.persisted?.should be_true

        refresh_elastic(Model::Module.table_name)

        params = HTTP::Params.encode({"q" => name_one})
        path = "#{Modules.base_route.rstrip('/')}?#{params}"
        header = Spec::Authentication.headers

        found = until_expected("GET", path, header) do |response|
          result = Array(Hash(String, JSON::Any)).from_json(response.body)
          result.any? { |r| r["id"].as_s == doc_one.id } && !result.any? { |r| r["id"].as_s == doc_two.id } ? true : false
        end

        found.should be_true
      end
    end

    describe "GET /modules/:id/settings" do
      it "collates Module settings" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        driver_settings_string = %(value: 0\nscreen: 0\nfrangos: 0\nchop: 0)
        Model::Generator.settings(driver: driver, settings_string: driver_settings_string).save!

        control_system = Model::Generator.control_system.save!
        control_system_settings_string = %(frangos: 1)
        Model::Generator.settings(control_system: control_system, settings_string: control_system_settings_string).save!

        zone = Model::Generator.zone.save!
        zone_settings_string = %(screen: 1)
        Model::Generator.settings(zone: zone, settings_string: zone_settings_string).save!

        control_system.zones = [zone.id.as(String)]
        control_system.update!

        mod = Model::Generator.module(driver: driver, control_system: control_system).save!
        module_settings_string = %(value: 2\n)
        Model::Generator.settings(mod: mod, settings_string: module_settings_string).save!

        expected_settings_ids = [
          mod.settings,
          control_system.settings,
          zone.settings,
          driver.settings,
        ].flat_map(&.compact_map(&.id)).reverse!

        path = File.join(Modules.base_route, "#{mod.id}/settings")
        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true

        settings = Array(Hash(String, JSON::Any)).from_json(result.body)
        settings_hierarchy_ids = settings.map &.["id"].to_s

        settings_hierarchy_ids.should eq expected_settings_ids
        {mod, control_system, zone, driver}.each &.destroy
      end

      it "returns an empty array for a logic module without associated settings" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!

        control_system = Model::Generator.control_system.save!

        zone = Model::Generator.zone.save!

        control_system.zones = [zone.id.as(String)]
        control_system.update!

        mod = Model::Generator.module(driver: driver, control_system: control_system).save!
        path = File.join(Modules.base_route, "#{mod.id}/settings")

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        unless result.success?
          puts "\ncode: #{result.status_code} body: #{result.body}"
        end

        result.success?.should be_true
        Array(JSON::Any).from_json(result.body).should be_empty
      end

      it "returns an empty array for a module without associated settings" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
        mod = Model::Generator.module(driver: driver).save!
        path = File.join(Modules.base_route, "#{mod.id}/settings")

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        unless result.success?
          puts "\ncode: #{result.status_code} body: #{result.body}"
        end

        result.success?.should be_true
        Array(JSON::Any).from_json(result.body).should be_empty
      end

      describe "POST /:id/ping" do
        it "fails for logic module" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Logic)
          mod = Model::Generator.module(driver: driver).save!
          path = File.join(Modules.base_route, "#{mod.id}/ping")
          result = client.post(
            path: path,
            headers: Spec::Authentication.headers,
          )

          result.success?.should be_false
          result.status_code.should eq 422
        end

        it "pings a module" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Device)
          driver.default_port = 8080
          driver.save!
          mod = Model::Generator.module(driver: driver)
          mod.ip = "127.0.0.1"
          mod.save!

          path = File.join(Modules.base_route, "#{mod.id}/ping")
          result = client.post(
            path: path,
            headers: Spec::Authentication.headers,
          )

          body = JSON.parse(result.body)
          result.success?.should be_true
          body["pingable"].should be_true
        end

        describe "scopes" do
          Spec.test_controller_scope(Modules)

          it "checks scope on update" do
            _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("modules", PlaceOS::Model::UserJWT::Scope::Access::Write)])
            driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
            mod = Model::Generator.module(driver: driver).save!

            connected = mod.connected
            mod.connected = !connected

            id = mod.id.as(String)
            path = File.join(Modules.base_route, id)

            result = Scopes.update(path, mod, scoped_headers)

            result.status_code.should eq 200
            updated = Model::Module.from_trusted_json(result.body)
            updated.id.should eq mod.id
            updated.connected.should eq !connected

            _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("modules", PlaceOS::Model::UserJWT::Scope::Access::Read)])
            result = Scopes.update(path, mod, scoped_headers)

            result.success?.should be_false
            result.status_code.should eq 403
          end
        end
      end
    end

    describe "POST /:id/start and POST /:id/stop" do
      it "allows support users to start and stop modules" do
        control_system = Model::Generator.control_system
        control_system.zones << Spec::Authentication.org_zone.id.as(String)
        control_system.zones_will_change!
        control_system.save!

        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        mod = Model::Generator.module(driver: driver, control_system: control_system)
        mod.running = false
        mod.save!

        id = mod.id.as(String)
        start_path = File.join(Modules.base_route, id, "start")
        stop_path = File.join(Modules.base_route, id, "stop")

        # Test that admin user can start a module
        result = client.post(
          path: start_path,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )

        result.status_code.should eq 200
        mod.reload!
        mod.running.should be_true

        # Test that admin user can stop a module
        result = client.post(
          path: stop_path,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )

        result.status_code.should eq 200
        mod.reload!
        mod.running.should be_false
      end
    end

    describe "support-subsystem permissions" do
      ::Spec.before_each { clear_group_tables }

      # Build a logic module attached to a control system whose only zone is
      # `zone`. The module derives its zones from that system, so granting on
      # `zone` (via a "support" GroupZone) gates access to the module.
      support_setup = ->(zone : Model::Zone) {
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        control_system = Model::Generator.control_system
        control_system.zones = [zone.id.as(String)]
        control_system.save!
        mod = Model::Generator.module(driver: driver, control_system: control_system)
        mod.running = false
        mod.save!
        mod
      }

      it "allows POST create for a user granted Create on the module's system zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!

        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Create).save!

        # a system the new logic module attaches to, scoped to `zone`
        control_system = Model::Generator.control_system
        control_system.zones = [zone.id.as(String)]
        control_system.save!

        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        mod = Model::Generator.module(driver: driver, control_system: control_system)
        mod.running = false

        result = client.post(Modules.base_route, body: mod.to_json, headers: headers)
        result.status_code.should eq 201

        created = Model::Module.from_trusted_json(result.body)
        created.destroy
        zone.destroy
      end

      it "rejects POST create when the user has only Read on the system zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        control_system = Model::Generator.control_system
        control_system.zones = [zone.id.as(String)]
        control_system.save!

        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        mod = Model::Generator.module(driver: driver, control_system: control_system)
        mod.running = false

        result = client.post(Modules.base_route, body: mod.to_json, headers: headers)
        result.status_code.should eq 403
        zone.destroy
      end

      it "allows PATCH update with Update on both sides, rejects with only Read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, update_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        mod = support_setup.call(zone)
        path = File.join(Modules.base_route, mod.id.as(String))

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Update).save!

        result = client.patch(path: path, body: mod.to_json, headers: update_headers)
        result.status_code.should eq 200

        # downgrade both sides to Read only => denied
        gu.permissions = Model::Permissions::Read.to_i
        gu.save!
        gz.permissions = Model::Permissions::Read.to_i
        gz.save!

        result = client.patch(path: path, body: mod.to_json, headers: update_headers)
        result.status_code.should eq 403

        mod.destroy
        zone.destroy
      end

      it "allows DELETE with Delete on both sides, rejects without" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        # Only Read => destroy denied
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        mod = support_setup.call(zone)
        path = File.join(Modules.base_route, mod.id.as(String))

        result = client.delete(path: path, headers: headers)
        result.status_code.should eq 403
        Model::Module.find?(mod.id.as(String)).should_not be_nil

        # grant Delete on both sides => allowed
        gu.permissions = Model::Permissions::Delete.to_i
        gu.save!
        gz.permissions = Model::Permissions::Delete.to_i
        gz.save!

        result = client.delete(path: path, headers: headers)
        result.success?.should be_true
        Model::Module.find?(mod.id.as(String)).should be_nil

        zone.destroy
      end

      it "rejects mutation of a module whose zones the user has no GroupZone reach for" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        # user has Manage on the group/zone A, but the module lives in zone B
        zone_a = Model::Generator.zone.save!
        zone_b = Model::Generator.zone.save!

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Manage).save!
        Model::Generator.group_zone(group: group, zone: zone_a, permissions: Model::Permissions::Manage).save!

        mod = support_setup.call(zone_b)
        path = File.join(Modules.base_route, mod.id.as(String))

        result = client.delete(path: path, headers: headers)
        result.status_code.should eq 403
        Model::Module.find?(mod.id.as(String)).should_not be_nil

        mod.destroy
        zone_a.destroy
        zone_b.destroy
      end

      it "gates start/stop on the Operate bit" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        mod = support_setup.call(zone)
        start_path = File.join(Modules.base_route, mod.id.as(String), "start")
        stop_path = File.join(Modules.base_route, mod.id.as(String), "stop")

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        # Delete bit is present but Operate is not => start denied
        gu = Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        gz = Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Delete).save!

        result = client.post(path: start_path, headers: headers)
        result.status_code.should eq 403
        mod.reload!
        mod.running.should be_false

        # grant Operate on both sides => start allowed
        gu.permissions = Model::Permissions::Operate.to_i
        gu.save!
        gz.permissions = Model::Permissions::Operate.to_i
        gz.save!

        result = client.post(path: start_path, headers: headers)
        result.status_code.should eq 200
        mod.reload!
        mod.running.should be_true

        result = client.post(path: stop_path, headers: headers)
        result.status_code.should eq 200
        mod.reload!
        mod.running.should be_false

        mod.destroy
        zone.destroy
      end

      it "lets a support-JWT user start regardless of group grants" do
        zone = Model::Generator.zone.save!
        mod = support_setup.call(zone)
        start_path = File.join(Modules.base_route, mod.id.as(String), "start")

        result = client.post(
          path: start_path,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 200
        mod.reload!
        mod.running.should be_true

        mod.destroy
        zone.destroy
      end

      it "lets admin and support JWT users create and destroy without any group" do
        zone = Model::Generator.zone.save!

        control_system = Model::Generator.control_system
        control_system.zones = [zone.id.as(String)]
        control_system.save!

        # support JWT create
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        mod = Model::Generator.module(driver: driver, control_system: control_system)
        mod.running = false

        result = client.post(
          Modules.base_route,
          body: mod.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: true),
        )
        result.status_code.should eq 201
        created = Model::Module.from_trusted_json(result.body)

        # admin JWT destroy
        result = client.delete(
          path: File.join(Modules.base_route, created.id.as(String)),
          headers: Spec::Authentication.headers(sys_admin: true, support: true),
        )
        result.success?.should be_true
        Model::Module.find?(created.id.as(String)).should be_nil

        zone.destroy
      end

      # ---- read scoping ----

      # A non-logic (device) module referenced by a control system scoped to
      # `zone`. Device modules are reachable via the system's `modules` array,
      # so the module derives its zones from that system.
      device_in_zone = ->(zone : Model::Zone) {
        driver = Model::Generator.driver(role: Model::Driver::Role::Device).save!
        mod = Model::Generator.module(driver: driver).save!
        cs = Model::Generator.control_system
        cs.zones = [zone.id.as(String)]
        cs.modules = [mod.id.as(String)]
        cs.save!
        {cs, mod}
      }

      it "allows show for a support user with Read on the module's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        cs, mod = device_in_zone.call(zone)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        result = client.get(path: "#{Modules.base_route}#{mod.id}", headers: headers)
        result.status_code.should eq 200

        mod.destroy
        cs.destroy
        zone.destroy
      end

      it "rejects show for a support user without a grant on the module's zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        cs, mod = device_in_zone.call(zone)

        # group exists but has no GroupZone reach to the module's zone
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        result = client.get(path: "#{Modules.base_route}#{mod.id}", headers: headers)
        result.status_code.should eq 403

        mod.destroy
        cs.destroy
        zone.destroy
      end

      it "allows index?control_system_id= with Read on the system zones and lists the modules" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        cs, mod = device_in_zone.call(zone)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        result = client.get(path: "#{Modules.base_route}?control_system_id=#{cs.id}", headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body).as_a.map(&.["id"].as_s).should contain(mod.id.as(String))

        mod.destroy
        cs.destroy
        zone.destroy
      end

      it "rejects index?control_system_id= for a support user without a grant" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        cs, mod = device_in_zone.call(zone)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        result = client.get(path: "#{Modules.base_route}?control_system_id=#{cs.id}", headers: headers)
        result.status_code.should eq 403

        mod.destroy
        cs.destroy
        zone.destroy
      end

      it "gates the whole module list: 403 with no accessible zones, 200 (scoped) with a grant" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        cs, mod = device_in_zone.call(zone)

        # no group/grant => no accessible zones => 403
        client.get(path: Modules.base_route, headers: headers).status_code.should eq 403

        # grant a reachable zone => allowed (result set is zone-scoped; contents
        # depend on ES indexing, so we only assert the gate opens)
        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        client.get(path: Modules.base_route, headers: headers).status_code.should eq 200

        mod.destroy
        cs.destroy
        zone.destroy
      end
    end
  end
end
