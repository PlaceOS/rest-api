require "http/web_socket"

require "../helper"

module PlaceOS::Api
  ::Spec.before_each do
    PlaceOS::Model::Module.clear
    PlaceOS::Model::Driver.clear
    PlaceOS::Model::ControlSystem.clear
  end

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

  # Build a non-admin user with a GroupUser + GroupZone wired to the
  # given subsystem and permission level, plus a ControlSystem in that
  # zone. Returns (cs, zone, group, headers).
  def self.setup_subsystem_cs(subsystem : String, perm : Model::Permissions)
    authority = Model::Authority.find_by_domain("localhost").not_nil!
    user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

    group = Model::Generator.group(authority: authority, subsystems: [subsystem]).save!
    Model::Generator.group_user(user: user, group: group, permissions: perm).save!

    zone = Model::Generator.zone.save!
    Model::Generator.group_zone(group: group, zone: zone, permissions: perm).save!

    cs = Model::Generator.control_system.save!
    cs.zones = [zone.id.as(String)]
    cs.save!

    {cs, zone, group, headers}
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

        it "non-admin / non-support user can list systems (baseline)" do
          # Confirms the current behaviour: a regular user with the
          # systems:read OAuth scope can call index without belonging to
          # any subsystem group. No per-user filtering is applied — they
          # see every system that matches the supplied filters.
          Model::ControlSystem.clear

          zone = Model::Generator.zone.save!
          mine = Model::Generator.control_system
          mine.zones = [zone.id.as(String)]
          mine.save!
          unrelated = Model::Generator.control_system.save!

          _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          refresh_elastic(Model::ControlSystem.table_name)
          found = until_expected("GET", Systems.base_route, headers) do |response|
            response.success? &&
              Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s).includes?(mine.id.as(String))
          end
          found.should be_true

          mine.destroy
          unrelated.destroy
          zone.destroy
        end

        it "non-admin user filtered by zone_id sees just that zone's systems (baseline)" do
          Model::ControlSystem.clear

          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)

          mine = Model::Generator.control_system
          mine.zones = [zone_id]
          mine.save!
          other = Model::Generator.control_system.save!

          _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          refresh_elastic(Model::ControlSystem.table_name)
          path = "#{Systems.base_route}?#{HTTP::Params.encode({"zone_id" => zone_id})}"
          found = until_expected("GET", path, headers) do |response|
            response.success? && begin
              ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
              ids.includes?(mine.id.as(String)) && !ids.includes?(other.id.as(String))
            end
          end
          found.should be_true

          mine.destroy
          other.destroy
          zone.destroy
        end

        it "group_id resolves to that group's GroupZone anchors" do
          clear_group_tables
          Model::ControlSystem.clear

          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

          anchor = Model::Generator.zone.save!
          Model::Generator.group_zone(group: group, zone: anchor, permissions: Model::Permissions::Read).save!

          in_anchor = Model::Generator.control_system
          in_anchor.zones = [anchor.id.as(String)]
          in_anchor.save!
          unrelated = Model::Generator.control_system.save!

          refresh_elastic(Model::ControlSystem.table_name)
          path = "#{Systems.base_route}?#{HTTP::Params.encode({"group_id" => group.id.to_s})}"
          found = until_expected("GET", path, headers) do |response|
            response.success? && begin
              ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
              ids.includes?(in_anchor.id.as(String)) && !ids.includes?(unrelated.id.as(String))
            end
          end
          found.should be_true

          in_anchor.destroy
          unrelated.destroy
          anchor.destroy
        end

        it "group_id is 403 for non-support callers without Read on the group" do
          clear_group_tables
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
          group = Model::Generator.group(authority: authority).save!

          path = "#{Systems.base_route}?#{HTTP::Params.encode({"group_id" => group.id.to_s})}"
          result = client.get(path, headers: headers)
          result.status_code.should eq 403
        end

        it "subsystem=signage returns systems in zones the caller can reach transitively" do
          clear_group_tables
          Model::ControlSystem.clear

          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

          # Anchor at parent_zone with a child zone underneath — the
          # accessible_zone_ids resolver expands the anchor down the
          # zone tree, so a system in the child should still show up.
          parent_zone = Model::Generator.zone.save!
          child_zone = Model::Generator.zone
          child_zone.parent_id = parent_zone.id
          child_zone.save!
          Model::Generator.group_zone(group: group, zone: parent_zone, permissions: Model::Permissions::Read).save!

          in_child = Model::Generator.control_system
          in_child.zones = [child_zone.id.as(String)]
          in_child.save!
          out_of_scope = Model::Generator.control_system.save!

          sleep 1.second
          refresh_elastic(Model::ControlSystem.table_name)
          path = "#{Systems.base_route}?#{HTTP::Params.encode({"subsystem" => "signage"})}"
          found = until_expected("GET", path, headers) do |response|
            response.success? && begin
              ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
              ids.includes?(in_child.id.as(String)) && !ids.includes?(out_of_scope.id.as(String))
            end
          end
          found.should be_true

          in_child.destroy
          out_of_scope.destroy
          child_zone.destroy
          parent_zone.destroy
        end

        it "subsystem returns empty when caller has no access" do
          clear_group_tables
          Model::ControlSystem.clear

          _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          existing = Model::Generator.control_system.save!

          refresh_elastic(Model::ControlSystem.table_name)
          path = "#{Systems.base_route}?#{HTTP::Params.encode({"subsystem" => "signage"})}"
          result = client.get(path, headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should be_empty

          existing.destroy
        end

        it "zone_id intersects with group_id scope — system needs both" do
          # Use case: zone_id is AND-style ("rooms tagged level-3 AND
          # meeting-room"), group_id contributes an OR scope of zones
          # the user is allowed to see. The two are combined with AND
          # so the result is "rooms matching the zone_id tags that are
          # also in one of the user's group zones".
          clear_group_tables
          Model::ControlSystem.clear

          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

          group_zone = Model::Generator.zone.save!
          Model::Generator.group_zone(group: group, zone: group_zone, permissions: Model::Permissions::Read).save!

          tag_zone = Model::Generator.zone.save!

          both = Model::Generator.control_system
          both.zones = [tag_zone.id.as(String), group_zone.id.as(String)]
          both.save!

          tag_only = Model::Generator.control_system
          tag_only.zones = [tag_zone.id.as(String)]
          tag_only.save!

          group_only = Model::Generator.control_system
          group_only.zones = [group_zone.id.as(String)]
          group_only.save!

          sleep 1.second
          refresh_elastic(Model::ControlSystem.table_name)
          params = HTTP::Params.encode({
            "zone_id"  => tag_zone.id.as(String),
            "group_id" => group.id.to_s,
          })
          path = "#{Systems.base_route}?#{params}"
          found = until_expected("GET", path, headers) do |response|
            response.success? && begin
              ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
              ids.includes?(both.id.as(String)) &&
                !ids.includes?(tag_only.id.as(String)) &&
                !ids.includes?(group_only.id.as(String))
            end
          end
          found.should be_true

          both.destroy
          tag_only.destroy
          group_only.destroy
          group_zone.destroy
          tag_zone.destroy
        end

        it "zone_id with multiple values requires the system to contain all of them" do
          # Confirms the existing AND semantic for zone_id — used to
          # combine zone tags so e.g. zone_id=level-3,meeting-room
          # returns only meeting rooms on level 3.
          Model::ControlSystem.clear

          a = Model::Generator.zone.save!
          b = Model::Generator.zone.save!

          both = Model::Generator.control_system
          both.zones = [a.id.as(String), b.id.as(String)]
          both.save!

          a_only = Model::Generator.control_system
          a_only.zones = [a.id.as(String)]
          a_only.save!

          sleep 1.second
          refresh_elastic(Model::ControlSystem.table_name)
          path = "#{Systems.base_route}?#{HTTP::Params.encode({"zone_id" => "#{a.id},#{b.id}"})}"
          found = until_expected("GET", path, Spec::Authentication.headers) do |response|
            response.success? && begin
              ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
              ids.includes?(both.id.as(String)) && !ids.includes?(a_only.id.as(String))
            end
          end
          found.should be_true

          both.destroy
          a_only.destroy
          a.destroy
          b.destroy
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

        it "should return systems by email" do
          Model::ControlSystem.clear
          num_systems = 5

          systems = Array.new(size: num_systems) do
            sys = Model::Generator.control_system
            sys.email = PlaceOS::Model::Email.new(Random.rand(9999).to_s + Faker::Internet.email)
            sys
          end

          # select a subset of systems
          systems.each &.save!
          expected_emails = systems.compact_map(&.email.to_s).sample(2)

          total_ids = expected_emails.size
          params = HTTP::Params.encode({"in" => expected_emails.join(',')})
          path = "#{Systems.base_route}with_emails?#{params}"

          result = client.get(
            path: path,
            headers: Spec::Authentication.headers,
          )
          returned_emails = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["email"].as_s)
          found = (returned_emails | expected_emails).size == total_ids
          found.should be_true
        end

        it "should return a systems by email or id" do
          Model::ControlSystem.clear
          num_systems = 5

          systems = Array.new(size: num_systems) do
            sys = Model::Generator.control_system
            sys.email = PlaceOS::Model::Email.new(Random.rand(9999).to_s + Faker::Internet.email)
            sys
          end

          # select a subset of systems
          systems.each &.save!
          system = systems.sample
          sys_id = system.id.not_nil!
          email = system.email.not_nil!.to_s

          path = "#{Systems.base_route}#{sys_id}/"
          result = client.get(
            path: path,
            headers: Spec::Authentication.headers,
          )
          id = Hash(String, JSON::Any).from_json(result.body)["id"].as_s
          id.should eq sys_id

          path = "#{Systems.base_route}#{email}/"
          result = client.get(
            path: path,
            headers: Spec::Authentication.headers,
          )
          id = Hash(String, JSON::Any).from_json(result.body)["email"].as_s
          id.should eq email
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
          sleep 1.second
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

        Model::Module.find?(mod_id).should be_nil
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

        Model::Module.find!(mod_id).should_not be_nil

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
      Spec.test_crd(Model::ControlSystem, Systems)

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.control_system.to_json
        result = client.post(
          Systems.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end

      it "fails to delete if a concierge user" do
        org_zone_id = Spec::Authentication.org_zone.id.as(String)
        auth_headers = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["concierge"])

        sys = PlaceOS::Model::Generator.control_system
        sys.zones << org_zone_id
        result = client.post(
          Systems.base_route,
          body: sys.to_json,
          headers: auth_headers
        )
        result.success?.should be_true

        sys = Model::ControlSystem.from_trusted_json result.body
        result = client.delete(
          path: "#{Systems.base_route}#{sys.id}",
          headers: auth_headers,
        )
        result.success?.should be_false
        result.status_code.should eq 403
      end

      it "management user can perform CRUD operations when in the org zone" do
        org_zone_id = Spec::Authentication.org_zone.id.as(String)
        auth_headers = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])

        sys = PlaceOS::Model::Generator.control_system
        sys.zones << org_zone_id
        result = client.post(
          Systems.base_route,
          body: sys.to_json,
          headers: auth_headers
        )
        result.success?.should be_true

        sys = Model::ControlSystem.from_trusted_json result.body
        result = client.delete(
          path: "#{Systems.base_route}#{sys.id}",
          headers: auth_headers,
        )
        result.success?.should be_true
      end

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

    describe "subsystem-based permissions" do
      ::Spec.before_each { clear_group_tables }

      it "PATCH allowed for 'signage' subsystem with Update perm" do
        cs, _zone, _group, headers = setup_subsystem_cs("signage", Model::Permissions::Update)

        # update requires a `version` query param to guard against
        # concurrent edits — pass the current value.
        result = client.patch(
          path: "#{Systems.base_route}#{cs.id}?version=#{cs.version}",
          body: {description: "renamed via signage"}.to_json,
          headers: headers,
        )
        result.success?.should be_true
        cs.reload!
        cs.description.should eq "renamed via signage"
      end

      it "PATCH allowed for 'support' subsystem with Update perm" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Update)

        result = client.patch(
          path: "#{Systems.base_route}#{cs.id}?version=#{cs.version}",
          body: {description: "renamed via support"}.to_json,
          headers: headers,
        )
        result.success?.should be_true
      end

      it "PATCH rejected when subsystem has only Read" do
        cs, _zone, _group, headers = setup_subsystem_cs("signage", Model::Permissions::Read)

        result = client.patch(
          path: "#{Systems.base_route}#{cs.id}?version=#{cs.version}",
          body: {description: "should fail"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
      end

      it "POST allowed for 'support' subsystem with Create perm on the proposed zone" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Create).save!

        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Create).save!

        new_cs = Model::Generator.control_system
        new_cs.zones = [zone.id.as(String)]

        result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
        result.status_code.should eq 201
      end

      it "DELETE allowed for 'support' subsystem with Delete perm" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Delete)

        result = client.delete(path: "#{Systems.base_route}#{cs.id}", headers: headers)
        result.success?.should be_true
        Model::ControlSystem.find?(cs.id.as(String)).should be_nil
      end

      it "DELETE rejected when 'support' has only Update (verb mismatch)" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Update)

        result = client.delete(path: "#{Systems.base_route}#{cs.id}", headers: headers)
        result.status_code.should eq 403
      end

      it "PUT add_module allowed for 'support' with Update perm" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Update)
        mod = Model::Generator.module(control_system: cs).save!

        result = client.put(
          path: "#{Systems.base_route}#{cs.id}/module/#{mod.id}",
          headers: headers,
        )
        result.status_code.should eq 200
      end

      it "DELETE remove_module allowed for 'support' with Delete perm" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Delete)
        mod = Model::Generator.module(control_system: cs).save!
        cs.update_fields(modules: [mod.id.as(String)])

        result = client.delete(
          path: "#{Systems.base_route}#{cs.id}/module/#{mod.id}",
          headers: headers,
        )
        result.success?.should be_true
      end

      it "POST start allowed for 'support' with Operate perm" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Operate)
        mod = Model::Generator.module(control_system: cs).save!
        cs.update_fields(modules: [mod.id.as(String)])

        result = client.post(path: "#{Systems.base_route}#{cs.id}/start", headers: headers)
        result.success?.should be_true
      end

      it "POST start rejected when 'support' has only Read (Operate missing)" do
        cs, _zone, _group, headers = setup_subsystem_cs("support", Model::Permissions::Read)

        result = client.post(path: "#{Systems.base_route}#{cs.id}/start", headers: headers)
        result.status_code.should eq 403
      end

      it "GET state rejected when 'support' has no perms" do
        # Set up a CS with a zone, but the user has no Read on that zone.
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        zone = Model::Generator.zone.save!
        cs = Model::Generator.control_system.save!
        cs.zones = [zone.id.as(String)]
        cs.save!

        mod = Model::Generator.module(control_system: cs).save!
        cs.update_fields(modules: [mod.id.as(String)])

        result = client.get(
          path: "#{Systems.base_route}#{cs.id}/#{mod.id}",
          headers: headers,
        )
        result.status_code.should eq 403
      end
    end
  end
end
