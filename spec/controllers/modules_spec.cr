require "../helper"
require "timecop"

module PlaceOS::Api
  describe Modules do
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
        response = client.get(
          "#{Modules.base_route}?#{HTTP::Params{"control_system_id" => sys.id.as(String)}}",
          headers: Spec::Authentication.headers,
        )

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

        it "connected" do
          mod = Model::Generator.module
          mod.ignore_connected = false
          mod.connected = true
          mod.save!
          mod.persisted?.should be_true

          params = HTTP::Params.encode({"connected" => "true"})
          path = "#{Modules.base_route}?#{params}"

          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body)

            all_connected = results.all? { |r| r["connected"].as_bool == true }
            contains_created = results.any? { |r| r["id"].as_s == mod.id }

            !results.empty? && all_connected && contains_created
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

        path = "#{Modules.base_route}#{mod.id}/settings"
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
        path = "#{Modules.base_route}#{mod.id}/settings"

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
        path = "#{Modules.base_route}#{mod.id}/settings"

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
          path = "#{Modules.base_route}#{mod.id}/ping"
          result = client.post(
            path: path,
            headers: Spec::Authentication.headers,
          )

          result.success?.should be_false
          result.status_code.should eq 406
        end

        it "pings a module" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Device)
          driver.default_port = 8080
          driver.save!
          mod = Model::Generator.module(driver: driver)
          mod.ip = "127.0.0.1"
          mod.save!

          path = "#{Modules.base_route}#{mod.id}/ping"
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
  end
end
