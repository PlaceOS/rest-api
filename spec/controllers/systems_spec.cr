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
  def self.setup_subsystem_cs(subsystem : String, perm : Model::Permissions, signage : Bool = false)
    authority = Model::Authority.find_by_domain("localhost").not_nil!
    user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

    group = Model::Generator.group(authority: authority, subsystems: [subsystem]).save!
    Model::Generator.group_user(user: user, group: group, permissions: perm).save!

    zone = Model::Generator.zone.save!
    Model::Generator.group_zone(group: group, zone: zone, permissions: perm).save!

    cs = Model::Generator.control_system
    cs.signage = signage
    cs.save!
    cs.zones = [zone.id.as(String)]
    cs.save!

    {cs, zone, group, headers}
  end

  # org -> building -> level; the user only has a `perm` grant on `level`
  # within `subsystem`. Returns (headers, org, building, level, unrelated).
  def self.setup_zone_hierarchy_create(subsystem : String = "support", perm : Model::Permissions = Model::Permissions::Create)
    authority = Model::Authority.find_by_domain("localhost").not_nil!
    user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

    org = Model::Generator.zone.save!
    building = Model::Generator.zone
    building.parent_id = org.id
    building.save!
    level = Model::Generator.zone
    level.parent_id = building.id
    level.save!
    unrelated = Model::Generator.zone.save!

    group = Model::Generator.group(authority: authority, subsystems: [subsystem]).save!
    Model::Generator.group_user(user: user, group: group, permissions: perm).save!
    Model::Generator.group_zone(group: group, zone: level, permissions: perm).save!

    {headers, org, building, level, unrelated}
  end

  def self.patch_zones(headers, cs, zones)
    client.patch(
      path: "#{Systems.base_route}#{cs.id}?version=#{cs.version}",
      body: {zones: zones}.to_json,
      headers: headers,
    )
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

          params = HTTP::Params.encode({"zone_id" => zone_id})
          path = "#{Systems.base_route}?#{params}"

          result = client.get(path, headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          returned_ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          returned_ids.sort.should eq expected_ids.sort
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

          result = client.get(Systems.base_route, headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(mine.id.as(String))
          ids.should contain(unrelated.id.as(String))

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

          path = "#{Systems.base_route}?#{HTTP::Params.encode({"zone_id" => zone_id})}"
          result = client.get(path, headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(mine.id.as(String))
          ids.should_not contain(other.id.as(String))

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

          path = "#{Systems.base_route}?#{HTTP::Params.encode({"group_id" => group.id.to_s})}"
          result = client.get(path, headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(in_anchor.id.as(String))
          ids.should_not contain(unrelated.id.as(String))

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

          path = "#{Systems.base_route}?#{HTTP::Params.encode({"subsystem" => "signage"})}"
          result = client.get(path, headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(in_child.id.as(String))
          ids.should_not contain(out_of_scope.id.as(String))

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

          params = HTTP::Params.encode({
            "zone_id"  => tag_zone.id.as(String),
            "group_id" => group.id.to_s,
          })
          path = "#{Systems.base_route}?#{params}"
          result = client.get(path, headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(both.id.as(String))
          ids.should_not contain(tag_only.id.as(String))
          ids.should_not contain(group_only.id.as(String))

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

          path = "#{Systems.base_route}?#{HTTP::Params.encode({"zone_id" => "#{a.id},#{b.id}"})}"
          result = client.get(path, headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(both.id.as(String))
          ids.should_not contain(a_only.id.as(String))

          both.destroy
          a_only.destroy
          a.destroy
          b.destroy
        end

        it "email filters systems by email (exact, case-insensitive)" do
          # NOTE: the Elasticsearch version of this filter was a no-op on
          # its own (optional `should` clause) and the old spec passed on
          # empty results. It is now a strict filter — pin the real
          # inclusion/exclusion behaviour.
          Model::ControlSystem.clear

          matched = Array.new(2) do |i|
            sys = Model::Generator.control_system
            sys.email = PlaceOS::Model::Email.new("room#{i}-#{Random.rand(9999)}@example.com")
            sys.save!
          end

          unmatched = Model::Generator.control_system
          unmatched.email = PlaceOS::Model::Email.new("other-#{Random.rand(9999)}@example.com")
          unmatched.save!
          no_email = Model::Generator.control_system.save!

          expected_ids = matched.compact_map(&.id)
          emails = matched.compact_map(&.email).map(&.to_s)

          params = HTTP::Params.encode({"email" => emails.join(',')})
          path = "#{Systems.base_route}?#{params}"

          result = client.get(path, headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          returned_ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          returned_ids.sort.should eq expected_ids.sort
          returned_ids.should_not contain(unmatched.id.as(String))
          returned_ids.should_not contain(no_email.id.as(String))

          # matching is case-insensitive
          params = HTTP::Params.encode({"email" => emails.first.upcase})
          result = client.get("#{Systems.base_route}?#{params}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          returned_ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          returned_ids.should eq [matched.first.id.as(String)]
        end

        it "email ANDs with the group_id scope instead of widening it" do
          # The Elasticsearch implementation merged email into the same
          # optional OR group as the zone scope, so a system merely
          # matching the email leaked into (widened) the authorization
          # scope. email is now a strict AND filter — a matching email
          # outside the scope must NOT be returned.
          clear_group_tables
          Model::ControlSystem.clear

          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

          zone = Model::Generator.zone.save!
          Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

          in_scope_match = Model::Generator.control_system
          in_scope_match.zones = [zone.id.as(String)]
          in_scope_match.email = PlaceOS::Model::Email.new("target-#{Random.rand(9999)}@example.com")
          in_scope_match.save!

          in_scope_other = Model::Generator.control_system
          in_scope_other.zones = [zone.id.as(String)]
          in_scope_other.email = PlaceOS::Model::Email.new("nomatch-#{Random.rand(9999)}@example.com")
          in_scope_other.save!

          out_of_scope_match = Model::Generator.control_system
          out_of_scope_match.email = PlaceOS::Model::Email.new("leaked-#{Random.rand(9999)}@example.com")
          out_of_scope_match.save!

          # ask for both the in-scope and the out-of-scope email — only
          # the in-scope system may come back
          emails = [in_scope_match.email, out_of_scope_match.email].compact.join(',', &.to_s)
          params = HTTP::Params.encode({
            "group_id" => group.id.to_s,
            "email"    => emails,
          })

          result = client.get("#{Systems.base_route}?#{params}", headers: headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [in_scope_match.id.as(String)]

          in_scope_match.destroy
          in_scope_other.destroy
          out_of_scope_match.destroy
          zone.destroy
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

          # Pin a non-logic role: Generator.module rolls a RANDOM driver role,
          # and a logic module gets attached to its own home system — which
          # then legitimately matches the module_id filter as an extra result.
          service_driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
          mod = Model::Generator.module(driver: service_driver).save!
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

          params = HTTP::Params.encode({"module_id" => module_id})
          path = "#{Systems.base_route}?#{params}"

          result = client.get(path, headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          returned_ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          returned_ids.sort.should eq expected_ids.sort
        end

        it "trigger_id filters systems to those with an instance of the trigger" do
          # The Elasticsearch implementation combined a has_child clause
          # with a document-type filter no document could satisfy, so
          # `?trigger_id=` always returned an empty list — this pins the
          # intended (fixed) behaviour.
          Model::ControlSystem.clear

          trigger = Model::Generator.trigger.save!
          with_trigger = Model::Generator.control_system.save!
          without_trigger = Model::Generator.control_system.save!
          instance = Model::Generator.trigger_instance(trigger, control_system: with_trigger).save!

          params = HTTP::Params.encode({"trigger_id" => trigger.id.as(String)})
          result = client.get("#{Systems.base_route}?#{params}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [with_trigger.id.as(String)]
          ids.should_not contain(without_trigger.id.as(String))

          # an unused trigger matches no systems
          other_trigger = Model::Generator.trigger.save!
          params = HTTP::Params.encode({"trigger_id" => other_trigger.id.as(String)})
          result = client.get("#{Systems.base_route}?#{params}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          Array(Hash(String, JSON::Any)).from_json(result.body).should be_empty

          instance.destroy
          trigger.destroy
          other_trigger.destroy
        end

        it "capacity returns systems with capacity equal or greater" do
          Model::ControlSystem.clear

          small = Model::Generator.control_system
          small.capacity = 2
          small.save!

          exact = Model::Generator.control_system
          exact.capacity = 5
          exact.save!

          large = Model::Generator.control_system
          large.capacity = 10
          large.save!

          result = client.get("#{Systems.base_route}?capacity=5", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.sort.should eq [exact.id.as(String), large.id.as(String)].sort
        end

        it "bookable filters on both true and false" do
          Model::ControlSystem.clear

          bookable_sys = Model::Generator.control_system
          bookable_sys.bookable = true
          bookable_sys.save!

          non_bookable = Model::Generator.control_system.save!

          result = client.get("#{Systems.base_route}?bookable=true", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [bookable_sys.id.as(String)]

          result = client.get("#{Systems.base_route}?bookable=false", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [non_bookable.id.as(String)]
        end

        it "signage filters on both true and false" do
          Model::ControlSystem.clear

          signage_sys = Model::Generator.control_system
          signage_sys.signage = true
          signage_sys.save!

          regular = Model::Generator.control_system.save!

          result = client.get("#{Systems.base_route}?signage=true", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [signage_sys.id.as(String)]

          result = client.get("#{Systems.base_route}?signage=false", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [regular.id.as(String)]
        end

        it "features requires all of the requested features" do
          Model::ControlSystem.clear

          full = Model::Generator.control_system
          full.features = Set{"whiteboard", "vidconf", "display"}
          full.save!

          partial = Model::Generator.control_system
          partial.features = Set{"whiteboard"}
          partial.save!

          none = Model::Generator.control_system.save!

          result = client.get("#{Systems.base_route}?features=whiteboard,vidconf", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [full.id.as(String)]

          # a single feature matches every system that has it
          result = client.get("#{Systems.base_route}?features=whiteboard", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.sort.should eq [full.id.as(String), partial.id.as(String)].sort
          ids.should_not contain(none.id.as(String))
        end

        it "public only filters when true" do
          Model::ControlSystem.clear

          public_sys = Model::Generator.control_system
          public_sys.public = true
          public_sys.save!

          private_sys = Model::Generator.control_system.save!

          result = client.get("#{Systems.base_route}?public=true", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [public_sys.id.as(String)]

          # `?public=false` does NOT filter (parity with the previous
          # behaviour) — both systems are returned
          result = client.get("#{Systems.base_route}?public=false", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.sort.should eq [public_sys.id.as(String), private_sys.id.as(String)].sort
        end

        it "q combines with zone_id filtering" do
          Model::ControlSystem.clear

          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)
          token = random_name

          match = Model::Generator.control_system
          match.name = "#{token} one"
          match.zones = [zone_id]
          match.save!

          same_zone = Model::Generator.control_system
          same_zone.zones = [zone_id]
          same_zone.save!

          same_name = Model::Generator.control_system
          same_name.name = "#{token} two"
          same_name.save!

          params = HTTP::Params.encode({"q" => token, "zone_id" => zone_id})
          result = client.get("#{Systems.base_route}?#{params}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should eq [match.id.as(String)]

          match.destroy
          same_zone.destroy
          same_name.destroy
          zone.destroy
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

        # single_occurrence=false uses control_system.modules directly; the default
        # (true) does a global GROUP BY ... HAVING COUNT(*)=1 over the whole `sys`
        # table, which is non-deterministic under the shared/parallel test DB
        path = Systems.base_route + "#{cs.id}/start?single_occurrence=false"

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

        # single_occurrence=false: see the start test above for why
        path = Systems.base_route + "#{cs.id}/stop?single_occurrence=false"

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

        # single_occurrence=false: see the start test above for why
        path = Systems.base_route + "#{cs.id}/start?single_occurrence=false"

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

      it "PATCH allowed for 'signage' subsystem with Update perm on a signage system" do
        cs, _zone, _group, headers = setup_subsystem_cs("signage", Model::Permissions::Update, signage: true)

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

      it "PATCH rejected for 'signage' subsystem when the system is not a signage display" do
        cs, _zone, _group, headers = setup_subsystem_cs("signage", Model::Permissions::Update, signage: false)

        result = client.patch(
          path: "#{Systems.base_route}#{cs.id}?version=#{cs.version}",
          body: {description: "should fail"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
      end

      it "PATCH rejected for 'signage' subsystem when turning signage off" do
        cs, _zone, _group, headers = setup_subsystem_cs("signage", Model::Permissions::Update, signage: true)

        result = client.patch(
          path: "#{Systems.base_route}#{cs.id}?version=#{cs.version}",
          body: {signage: false}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
        cs.reload!
        cs.signage.should be_true
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

      describe "POST with a zone hierarchy" do
        it "allows the granted zone together with its ancestor zones" do
          headers, org, building, level, _unrelated = setup_zone_hierarchy_create

          new_cs = Model::Generator.control_system
          new_cs.zones = [level.id.as(String), building.id.as(String), org.id.as(String)]

          result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
          result.status_code.should eq 201
          created = Model::ControlSystem.from_trusted_json(result.body)
          created.zones.should eq [level.id, building.id, org.id]
        end

        it "rejects when only ancestor zones (no granted zone) are specified" do
          headers, org, building, _level, _unrelated = setup_zone_hierarchy_create

          new_cs = Model::Generator.control_system
          new_cs.zones = [building.id.as(String), org.id.as(String)]

          result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
          result.status_code.should eq 403
        end

        it "rejects when an unrelated zone is included alongside the granted zone" do
          headers, org, building, level, unrelated = setup_zone_hierarchy_create

          new_cs = Model::Generator.control_system
          new_cs.zones = [level.id.as(String), building.id.as(String), org.id.as(String), unrelated.id.as(String)]

          result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
          result.status_code.should eq 403
        end

        it "'signage' subsystem can create a signage system in the granted zone and its ancestors" do
          headers, org, building, level, _unrelated = setup_zone_hierarchy_create("signage")

          new_cs = Model::Generator.control_system
          new_cs.signage = true
          new_cs.zones = [level.id.as(String), building.id.as(String), org.id.as(String)]

          result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
          result.status_code.should eq 201
        end

        it "'signage' subsystem cannot create a non-signage system" do
          headers, _org, _building, level, _unrelated = setup_zone_hierarchy_create("signage")

          new_cs = Model::Generator.control_system
          new_cs.signage = false
          new_cs.zones = [level.id.as(String)]

          result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
          result.status_code.should eq 403
        end

        it "'signage' subsystem cannot attach an unrelated zone to a signage system" do
          headers, _org, _building, level, unrelated = setup_zone_hierarchy_create("signage")

          new_cs = Model::Generator.control_system
          new_cs.signage = true
          new_cs.zones = [level.id.as(String), unrelated.id.as(String)]

          result = client.post(Systems.base_route, body: new_cs.to_json, headers: headers)
          result.status_code.should eq 403
        end
      end

      describe "PATCH zones with a zone hierarchy" do
        it "allows adding ancestor zones of the granted zone" do
          headers, org, building, level, _unrelated = setup_zone_hierarchy_create("support", Model::Permissions::Update)
          cs = Model::Generator.control_system
          cs.zones = [level.id.as(String)]
          cs.save!

          result = patch_zones(headers, cs, [level.id, building.id, org.id])
          result.status_code.should eq 200
          cs.reload!
          cs.zones.should eq [level.id, building.id, org.id]
        end

        it "rejects adding an unrelated zone" do
          headers, _org, _building, level, unrelated = setup_zone_hierarchy_create("support", Model::Permissions::Update)
          cs = Model::Generator.control_system
          cs.zones = [level.id.as(String)]
          cs.save!

          result = patch_zones(headers, cs, [level.id, unrelated.id])
          result.status_code.should eq 403
          cs.reload!
          cs.zones.should eq [level.id]
        end

        it "does not re-check zones already on the system when adding an ancestor" do
          headers, _org, building, level, unrelated = setup_zone_hierarchy_create("support", Model::Permissions::Update)
          # an admin previously placed the system in an extra, unrelated zone
          cs = Model::Generator.control_system
          cs.zones = [level.id.as(String), unrelated.id.as(String)]
          cs.save!

          result = patch_zones(headers, cs, [level.id, unrelated.id, building.id])
          result.status_code.should eq 200
          cs.reload!
          cs.zones.should eq [level.id, unrelated.id, building.id]
        end

        it "'signage' subsystem can add ancestor zones to a signage system" do
          headers, org, building, level, _unrelated = setup_zone_hierarchy_create("signage", Model::Permissions::Update)
          cs = Model::Generator.control_system
          cs.signage = true
          cs.zones = [level.id.as(String)]
          cs.save!

          result = patch_zones(headers, cs, [level.id, building.id, org.id])
          result.status_code.should eq 200
        end

        it "'signage' subsystem cannot add an unrelated zone to a signage system" do
          headers, _org, _building, level, unrelated = setup_zone_hierarchy_create("signage", Model::Permissions::Update)
          cs = Model::Generator.control_system
          cs.signage = true
          cs.zones = [level.id.as(String)]
          cs.save!

          result = patch_zones(headers, cs, [level.id, unrelated.id])
          result.status_code.should eq 403
        end
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
