require "http/web_socket"

require "../helper"

module PlaceOS::Api
  def self.spec_add_module(system, mod, headers)
    mod_id = mod.id.as(String)
    path = Systems::NAMESPACE.first + "#{system.id}/module/#{mod_id}"

    result = client.put(
      path: path,
      headers: headers,
    )

    result.status_code.should eq 200
    system = Model::ControlSystem.from_trusted_json(result.body)
    system.modules.should contain mod_id
    system
  end

  def self.spec_delete_module(system, mod, headers)
    mod_id = mod.id.as(String)

    path = Systems::NAMESPACE.first + "#{system.id}/module/#{mod_id}"

    result = client.delete(
      path: path,
      headers: headers,
    )

    result.success?.should be_true
    system = Model::ControlSystem.from_trusted_json(result.body)
    system.modules.should_not contain mod_id
    system
  end

  describe Systems do
    Spec.test_404(Systems.base_route, model_name: Model::ControlSystem.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(klass: Model::ControlSystem, controller_klass: Systems)

      context "query parameter" do
        it "zone_id filters systems by zones" do
          Model::ControlSystem.clear

          num_systems = 5

          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          expected_systems.each do |sys|
            sys.zones = [zone_id]
          end
          systems.each &.save!

          expected_ids = expected_systems.compact_map(&.id)
          total_ids = expected_ids.size

          params = HTTP::Params.encode({"zone_id" => zone_id})
          path = "#{Systems.base_route}?#{params}"

          refresh_elastic(Model::ControlSystem.table_name)
          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            returned_ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            (returned_ids | expected_ids).size == total_ids
          end

          found.should be_true
        end

        it "email filters systems by email" do
          Model::ControlSystem.clear
          num_systems = 5

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          systems.each &.save!

          expected_emails = expected_systems.compact_map(&.email)
          expected_ids = expected_systems.compact_map(&.id)

          total_ids = expected_ids.size
          params = HTTP::Params.encode({"email" => expected_emails.join(',')})
          path = "#{Systems.base_route}?#{params}"

          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            refresh_elastic(Model::ControlSystem.table_name)
            returned_ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            (returned_ids | expected_ids).size == total_ids
          end

          found.should be_true
        end

        it "module_id filters systems by modules" do
          Model::ControlSystem.clear
          num_systems = 5

          mod = Model::Generator.module.save!
          module_id = mod.id.as(String)

          systems = Array.new(size: num_systems) do
            Model::Generator.control_system
          end

          # Add the zone to a subset of systems
          expected_systems = systems.shuffle[0..2]
          expected_systems.each do |sys|
            sys.modules = [module_id]
          end
          systems.each &.save!

          expected_ids = expected_systems.compact_map(&.id)
          total_ids = expected_ids.size

          params = HTTP::Params.encode({"module_id" => module_id})
          path = "#{Systems.base_route}?#{params}"

          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            refresh_elastic(Model::ControlSystem.table_name)
            returned_ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            (returned_ids | expected_ids).size == total_ids
          end

          found.should be_true
        end
      end
    end

    describe "GET /systems/:sys_id/zones" do
      it "lists zones for a system" do
        control_system = Model::Generator.control_system.save!

        zone0 = Model::Generator.zone.save!
        zone1 = Model::Generator.zone.save!

        control_system.zones = [zone0.id.as(String), zone1.id.as(String)]
        control_system.save!

        path = Systems.base_route + "#{control_system.id}/zones"

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        documents = Array(Hash(String, JSON::Any)).from_json(result.body)
        documents.size.should eq 2
        documents.map(&.["id"].as_s).sort!.should eq [zone0.id, zone1.id].compact.sort!
      end
    end

    describe "PUT /systems/:sys_id/module/:module_id" do
      it "adds a module if not present" do
        cs = Model::Generator.control_system.save!
        mod = Model::Generator.module.save!
        cs.persisted?.should be_true
        mod.persisted?.should be_true

        spec_add_module(cs, mod, Spec::Authentication.headers)
        {cs, mod}.each &.destroy
      end

      it "404s if added module does not exist" do
        cs = Model::Generator.control_system.save!
        cs.persisted?.should be_true

        path = Systems.base_route + "#{cs.id}/module/mod-th15do35n073x157"

        result = client.put(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 404
        cs.destroy
      end

      it "adds module after removal from system" do
        cs1 = Model::Generator.control_system.save!
        cs2 = Model::Generator.control_system.save!

        mod = Model::Generator.module.save!

        cs1.persisted?.should be_true
        cs2.persisted?.should be_true
        mod.persisted?.should be_true

        cs1 = spec_add_module(cs1, mod, Spec::Authentication.headers)

        spec_add_module(cs2, mod, Spec::Authentication.headers)

        cs1 = spec_delete_module(cs1, mod, Spec::Authentication.headers)

        spec_add_module(cs1, mod, Spec::Authentication.headers)
      end
    end

    describe "DELETE /systems/:sys_id/module/:module_id" do
      it "removes if not in use by another ControlSystem" do
        cs = Model::Generator.control_system.save!
        mod = Model::Generator.module(control_system: cs).save!
        cs.persisted?.should be_true
        mod.persisted?.should be_true

        mod_id = mod.id.as(String)
        cs_id = cs.id.as(String)

        Model::ControlSystem.add_module(cs_id, mod_id)

        mod_id = mod.id.as(String)

        spec_delete_module(cs, mod, Spec::Authentication.headers)

        Model::Module.find(mod_id).should be_nil
        {mod, cs}.each &.try &.destroy
      end

      it "keeps module if in use by another ControlSystem" do
        cs1 = Model::Generator.control_system.save!
        cs2 = Model::Generator.control_system.save!
        mod = Model::Generator.module.save!
        cs1.persisted?.should be_true
        cs2.persisted?.should be_true
        mod.persisted?.should be_true

        mod_id = mod.id.as(String)
        # Add module to systems
        cs1.update_fields(modules: [mod_id])
        cs2.update_fields(modules: [mod_id])

        cs1.modules.should contain mod_id
        cs2.modules.should contain mod_id

        cs1 = spec_delete_module(cs1, mod, Spec::Authentication.headers)

        cs2 = Model::ControlSystem.find!(cs2.id.as(String))
        cs2.modules.should contain mod_id

        Model::Module.find(mod_id).should_not be_nil

        {mod, cs1, cs2}.each &.destroy
      end
    end

    describe "GET /systems/:sys_id/settings" do
      it "collates System settings" do
        control_system = Model::Generator.control_system.save!
        control_system_settings_string = %(frangos: 1)
        Model::Generator.settings(control_system: control_system, settings_string: control_system_settings_string).save!

        zone0 = Model::Generator.zone.save!
        zone0_settings_string = %(screen: 1)
        Model::Generator.settings(zone: zone0, settings_string: zone0_settings_string).save!
        zone1 = Model::Generator.zone.save!
        zone1_settings_string = %(meme: 2)
        Model::Generator.settings(zone: zone1, settings_string: zone1_settings_string).save!

        control_system.zones = [zone0.id.as(String), zone1.id.as(String)]
        control_system.update!

        expected_settings_ids = [
          control_system.settings,
          zone1.settings,
          zone0.settings,
        ].flat_map(&.compact_map(&.id)).reverse!

        path = File.join(Systems.base_route, "#{control_system.id}/settings")
        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true

        settings = Array(Hash(String, JSON::Any)).from_json(result.body)
        settings_hierarchy_ids = settings.map &.["id"].to_s

        settings_hierarchy_ids.should eq expected_settings_ids
        {control_system, zone0, zone1}.each &.destroy
      end

      it "returns an empty array for a system without associated settings" do
        control_system = Model::Generator.control_system.save!

        zone0 = Model::Generator.zone.save!
        zone1 = Model::Generator.zone.save!

        control_system.zones = [zone0.id.as(String), zone1.id.as(String)]
        control_system.save!
        path = File.join(Systems.base_route, "#{control_system.id}/settings")

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
    end

    it "GET /systems/:sys_id/functions/:module_slug" do
      cs = PlaceOS::Model::Generator.control_system.save!
      mod = PlaceOS::Model::Generator.module(control_system: cs).save!
      module_slug = mod.id.as(String)

      sys_lookup = PlaceOS::Driver::RedisStorage.new(cs.id.as(String), "system")
      lookup_key = "#{module_slug}/1"
      sys_lookup[lookup_key] = module_slug

      PlaceOS::Driver::RedisStorage.with_redis do |redis|
        meta = PlaceOS::Driver::DriverModel::Metadata.new({
          "function1" => {} of String => JSON::Any,
          "function2" => {"arg1" => JSON.parse(%({"type":"integer"}))},
          "function3" => {"arg1" => JSON.parse(%({"type":"integer"})), "arg2" => JSON.parse(%({"type":"integer","default":200}))},
        }, ["Functoids"])

        redis.set("interface/#{module_slug}", meta.to_json)
      end

      path = Systems.base_route + "#{cs.id}/functions/#{module_slug}"

      result = client.get(
        path: path,
        headers: Spec::Authentication.headers,
      )

      result.body.includes?("function1").should be_true
    end

    describe "GET /systems/:sys_id/types" do
      it "returns types of modules in a system" do
        expected = {
          "Display"  => 2,
          "Switcher" => 1,
          "Camera"   => 3,
          "Bookings" => 1,
        }

        cs = Model::Generator.control_system.save!
        mods = expected.flat_map do |name, count|
          Array(Model::Module).new(size: count) do
            mod = Model::Generator.module
            mod.custom_name = name
            mod.save!
          end
        end

        cs.modules = mods.compact_map(&.id)
        cs.update!

        path = Systems.base_route + "#{cs.id}/types"

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        types = Hash(String, Int32).from_json(result.body)

        types.should eq expected

        mods.each &.destroy
        cs.destroy
      end
    end

    context "with core" do
      mod, cs = get_sys

      # "fetches the state for `key` in module defined by `module_slug`
      it "GET /systems/:sys_id/:module_slug/:key" do
        module_slug = cs.modules.first

        # Create a storage proxy
        driver_proxy = PlaceOS::Driver::RedisStorage.new mod.id.as(String)

        status_name = "orange"
        driver_proxy[status_name] = 1

        sys_lookup = PlaceOS::Driver::RedisStorage.new(cs.id.as(String), "system")
        lookup_key = "#{module_slug}/1"
        sys_lookup[lookup_key] = mod.id.as(String)

        path = Systems.base_route + "#{cs.id}/#{module_slug}/orange"

        response = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        Int32.from_json(response.body).should eq(1)
      end

      it "GET /systems/:sys_id/:module_slug" do
        module_slug = cs.modules.first

        # Create a storage proxy
        driver_proxy = PlaceOS::Driver::RedisStorage.new mod.id.as(String)

        status_name = "nugget"
        driver_proxy[status_name] = 1

        sys_lookup = PlaceOS::Driver::RedisStorage.new(cs.id.as(String), "system")
        lookup_key = "#{module_slug}/1"
        sys_lookup[lookup_key] = mod.id.as(String)

        path = Systems.base_route + "#{cs.id}/#{module_slug}"

        response = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        state = Hash(String, String).from_json(response.body)
        state["nugget"].should eq("1")
      end
    end

    describe "POST /systems/:sys_id/start" do
      it "start modules in a system" do
        cs = Model::Generator.control_system.save!
        mod = Model::Generator.module(control_system: cs).save!
        cs.update_fields(modules: [mod.id.as(String)])

        cs.persisted?.should be_true
        mod.persisted?.should be_true
        mod.running.should be_false

        path = Systems.base_route + "#{cs.id}/start"

        result = client.post(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        Model::Module.find!(mod.id.as(String)).running.should be_true

        mod.destroy
        cs.destroy
      end
    end

    describe "POST /systems/:sys_id/stop" do
      it "stops modules in a system" do
        cs = Model::Generator.control_system.save!
        mod = Model::Generator.module(control_system: cs)
        mod.running = true
        mod.save!
        cs.update_fields(modules: [mod.id.as(String)])

        cs.persisted?.should be_true
        mod.persisted?.should be_true
        mod.running.should be_true

        path = Systems.base_route + "#{cs.id}/stop"

        result = client.post(
          path: path,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        Model::Module.find!(mod.id.as(String)).running.should be_false

        mod.destroy
        cs.destroy
      end
    end

    describe "GET /systems/:sys_id/metadata" do
      it "shows system metadata" do
        system = Model::Generator.control_system.save!
        system_id = system.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: system_id).save!

        result = client.get(
          path: Systems.base_route + "#{system_id}/metadata",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
        metadata.first[1].parent_id.should eq system_id
        metadata.first[1].name.should eq meta.name

        system.destroy
        meta.destroy
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(klass: Model::ControlSystem, controller_klass: Systems)

      describe "update" do
        it "if version is valid" do
          cs = Model::Generator.control_system.save!
          cs.persisted?.should be_true

          original_name = cs.name
          cs.name = random_name

          id = cs.id.as(String)

          params = HTTP::Params.encode({"version" => "0"})
          path = "#{File.join(Systems.base_route, id)}?#{params}"

          result = client.patch(
            path: path,
            body: cs.to_json,
            headers: Spec::Authentication.headers,
          )

          result.status_code.should eq 200
          updated = Model::ControlSystem.from_trusted_json(result.body)
          updated.id.should eq cs.id
          updated.name.should_not eq original_name
        end

        it "fails when version is invalid" do
          cs = Model::Generator.control_system.save!
          id = cs.id.as(String)
          cs.persisted?.should be_true

          params = HTTP::Params.encode({"version" => "2"})
          path = "#{File.join(Systems.base_route, id)}?#{params}"

          result = client.patch(
            path: path,
            body: cs.to_json,
            headers: Spec::Authentication.headers,
          )

          result.status_code.should eq 409
        end
      end
    end

    describe "GET /systems/:id/metadata" do
      it "shows system metadata" do
        system = Model::Generator.control_system.save!
        system_id = system.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: system_id).save!

        result = client.get(
          path: Systems.base_route + "#{system_id}/metadata",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
        metadata.first[1].parent_id.should eq system_id
        metadata.first[1].name.should eq meta.name

        system.destroy
        meta.destroy
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Systems)
      it "should not allow start" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("systems", :read)])

        cs = Model::Generator.control_system.save!
        mod = Model::Generator.module(control_system: cs).save!
        cs.update_fields(modules: [mod.id.as(String)])

        cs.persisted?.should be_true
        mod.persisted?.should be_true
        mod.running.should be_false

        path = Systems.base_route + "#{cs.id}/start"

        result = client.post(
          path: path,
          headers: scoped_headers,
        )

        result.status_code.should eq 403
      end

      it "should allow start" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("systems", :write)])

        cs = Model::Generator.control_system.save!
        mod = Model::Generator.module(control_system: cs).save!
        cs.update_fields(modules: [mod.id.as(String)])

        cs.persisted?.should be_true
        mod.persisted?.should be_true
        mod.running.should be_false

        path = Systems.base_route + "#{cs.id}/start"

        result = client.post(
          path: path,
          headers: scoped_headers,
        )

        result.status_code.should eq 200
        Model::Module.find!(mod.id.as(String)).running.should be_true

        mod.destroy
        cs.destroy
      end
    end
  end
end
