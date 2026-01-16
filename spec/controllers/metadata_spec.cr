require "../helper"
require "timecop"

module PlaceOS::Api
  describe Metadata do
    describe "GET /metadata/:id/children/" do
      it "shows zone children metadata" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        3.times do
          child = Model::Generator.zone
          child.parent_id = parent_id
          child.save!
          Model::Generator.metadata(parent: child.id).save!
        end

        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children",
          headers: Spec::Authentication.headers,
        )

        Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
          .tap(&.size.should eq(3))
          .count(&.[:metadata].empty?.!)
          .should eq 3

        parent.destroy
      end

      it "filters zone children metadata" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        children = Array.new(size: 3) do
          child = Model::Generator.zone
          child.parent_id = parent_id
          child.save!
          Model::Generator.metadata(parent: child.id).save!
          child
        end

        # Create a single special metadata to filter on
        Model::Generator.metadata(name: "special", parent: children.first.id).save!

        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children?name=special",
          headers: Spec::Authentication.headers,
        )

        Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
          .count(&.[:metadata].empty?.!)
          .should eq 1

        parent.destroy
      end

      it "filters zone children by single tag" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        # Create children with different tags
        child1 = Model::Generator.zone
        child1.parent_id = parent_id
        child1.tags = Set{"building", "level1"}
        child1.save!
        Model::Generator.metadata(parent: child1.id).save!

        child2 = Model::Generator.zone
        child2.parent_id = parent_id
        child2.tags = Set{"room", "level2"}
        child2.save!
        Model::Generator.metadata(parent: child2.id).save!

        child3 = Model::Generator.zone
        child3.parent_id = parent_id
        child3.tags = Set{"building", "lobby"}
        child3.save!
        Model::Generator.metadata(parent: child3.id).save!

        # Test filtering by "building" tag - should return child1 and child3
        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children?tags=building",
          headers: Spec::Authentication.headers,
        )

        children_result = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
        children_result.size.should eq 2

        # Verify the correct zones are returned
        zone_ids = children_result.map(&.[:zone]["id"].as_s)
        zone_ids.should contain(child1.id)
        zone_ids.should contain(child3.id)

        parent.destroy
      end

      it "filters zone children by multiple tags" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        # Create children with different tags
        child1 = Model::Generator.zone
        child1.parent_id = parent_id
        child1.tags = Set{"building", "level1"}
        child1.save!
        Model::Generator.metadata(parent: child1.id).save!

        child2 = Model::Generator.zone
        child2.parent_id = parent_id
        child2.tags = Set{"room", "level2"}
        child2.save!
        Model::Generator.metadata(parent: child2.id).save!

        child3 = Model::Generator.zone
        child3.parent_id = parent_id
        child3.tags = Set{"building", "lobby"}
        child3.save!
        Model::Generator.metadata(parent: child3.id).save!

        # Test filtering by multiple tags - should return zones with either tag
        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children?tags=building,room",
          headers: Spec::Authentication.headers,
        )

        children_result = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
        children_result.size.should eq 3

        parent.destroy
      end

      it "returns empty result when no zones match tag filter" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        # Create children with tags that don't match the filter
        child1 = Model::Generator.zone
        child1.parent_id = parent_id
        child1.tags = Set{"building", "level1"}
        child1.save!
        Model::Generator.metadata(parent: child1.id).save!

        child2 = Model::Generator.zone
        child2.parent_id = parent_id
        child2.tags = Set{"room", "level2"}
        child2.save!
        Model::Generator.metadata(parent: child2.id).save!

        # Test filtering by non-existent tag
        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children?tags=nonexistent",
          headers: Spec::Authentication.headers,
        )

        children_result = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
        children_result.size.should eq 0

        parent.destroy
      end

      it "returns all zones when no tag filter is provided" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        # Create children with tags
        3.times do |i|
          child = Model::Generator.zone
          child.parent_id = parent_id
          child.tags = Set{"tag#{i}"}
          child.save!
          Model::Generator.metadata(parent: child.id).save!
        end

        # Test without tag filter - should return all zones
        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children",
          headers: Spec::Authentication.headers,
        )

        children_result = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
        children_result.size.should eq 3

        parent.destroy
      end

      it "combines tag filter with name filter" do
        parent = Model::Generator.zone.save!
        parent_id = parent.id.as(String)

        # Create children with tags
        child1 = Model::Generator.zone
        child1.parent_id = parent_id
        child1.tags = Set{"building"}
        child1.save!
        Model::Generator.metadata(name: "special", parent: child1.id).save!

        child2 = Model::Generator.zone
        child2.parent_id = parent_id
        child2.tags = Set{"building"}
        child2.save!
        Model::Generator.metadata(name: "regular", parent: child2.id).save!

        child3 = Model::Generator.zone
        child3.parent_id = parent_id
        child3.tags = Set{"room"}
        child3.save!
        Model::Generator.metadata(name: "special", parent: child3.id).save!

        # Test combining tag and name filters - should return only child1
        result = client.get(
          path: "#{Metadata.base_route}/#{parent_id}/children?tags=building&name=special",
          headers: Spec::Authentication.headers,
        )

        children_result = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
          .from_json(result.body)
        children_result.size.should eq 1
        children_result.first[:zone]["id"].as_s.should eq child1.id

        parent.destroy
      end
    end

    describe "PUT /metadata" do
      it "creates metadata" do
        parent = Model::Generator.zone.save!

        meta = Model::Metadata::Interface.new(
          name: "test",
          description: "",
          details: JSON.parse(%({"hello":"world","bye":"friends"})),
          parent_id: nil,
          editors: Set(String).new,
        )

        parent_id = parent.id.as(String)
        path = "#{Api::Metadata.base_route}/#{parent_id}"

        result = client.put(
          path: path,
          body: meta.to_json,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true

        new_metadata = Model::Metadata::Interface.from_json(result.body)
        found = Model::Metadata.for(parent.id.as(String), meta.name).first
        found.name.should eq new_metadata.name
      end

      it "creates metadata as a regular user and prevents delete" do
        parent = Model::Generator.zone
        parent.parent_id = Spec::Authentication.org_zone.id
        parent.save!

        meta = Model::Metadata::Interface.new(
          name: "test2",
          description: "",
          details: JSON.parse(%({"hello":"world","bye":"friends"})),
          parent_id: nil,
          editors: Set(String).new,
        )

        parent_id = parent.id.as(String)
        path = "#{Api::Metadata.base_route}/#{parent_id}?name=test2"

        auth_headers = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["concierge"])
        result = client.put(
          path: path,
          body: meta.to_json,
          headers: auth_headers,
        )

        result.success?.should be_true

        new_metadata = Model::Metadata::Interface.from_json(result.body)
        found = Model::Metadata.for(parent.id.as(String), meta.name).first
        found.name.should eq new_metadata.name

        # attempt remove of metadata
        result = client.delete(
          path: "#{Metadata.base_route}/#{parent_id}",
          headers: auth_headers,
        )
        result.success?.should be_false
        result.status_code.should eq 403
      end

      it "creates metadata as a regular user and allows delete" do
        parent = Model::Generator.zone
        parent.parent_id = Spec::Authentication.org_zone.id
        parent.save!

        meta = Model::Metadata::Interface.new(
          name: "test3",
          description: "",
          details: JSON.parse(%({"hello":"world","bye":"friends"})),
          parent_id: nil,
          editors: Set(String).new,
        )

        parent_id = parent.id.as(String)
        path = "#{Api::Metadata.base_route}/#{parent_id}"

        auth_headers = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])
        result = client.put(
          path: path,
          body: meta.to_json,
          headers: auth_headers,
        )

        result.success?.should be_true

        new_metadata = Model::Metadata::Interface.from_json(result.body)
        found = Model::Metadata.for(parent.id.as(String), meta.name).first
        found.name.should eq new_metadata.name

        # attempt remove of metadata
        result = client.delete(
          path: "#{Metadata.base_route}/#{parent_id}?name=test3",
          headers: auth_headers,
        )

        result.status_code.should eq 202
        result.success?.should be_true
      end

      it "returns forbidden when attempting to create metadata as a regular user" do
        parent = Model::Generator.zone
        parent.parent_id = Spec::Authentication.org_zone.id
        parent.save!

        meta = Model::Metadata::Interface.new(
          name: "test4",
          description: "",
          details: JSON.parse(%({"hello":"world","bye":"friends"})),
          parent_id: nil,
          editors: Set(String).new,
        )

        parent_id = parent.id.as(String)
        path = "#{Api::Metadata.base_route}/#{parent_id}"

        result = client.put(
          path: path,
          body: meta.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false),
        )

        result.success?.should be_false
        result.status_code.should eq 403
      end

      it "updates metadata" do
        parent = Model::Generator.zone.save!
        meta = Model::Metadata::Interface.new(
          name: "test",
          description: "",
          details: JSON.parse(%({"hello":"world","bye":"friends"})),
          parent_id: nil,
          editors: Set(String).new,
        )

        parent_id = parent.id.as(String)
        path = "#{Metadata.base_route}/#{parent_id}"

        result = client.put(
          path: path,
          body: meta.to_json,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true

        new_metadata = Model::Metadata::Interface.from_json(result.body)
        found = Model::Metadata.for(parent_id, meta.name).first
        found.name.should eq new_metadata.name

        updated_meta = Model::Metadata::Interface.new(
          name: "test",
          description: "",
          details: JSON.parse(%({"hello":"world"})),
          parent_id: nil,
          editors: Set(String).new,
        )

        result = client.put(
          path: path,
          body: updated_meta.to_json,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true

        update_response_meta = Model::Metadata::Interface.from_json(result.body)
        update_response_meta.details.as_h["bye"]?.should be_nil

        found = Model::Metadata.for(parent_id, meta.name).first
        found.details.as_h["bye"]?.should be_nil
      end
    end

    describe "GET /metadata/:id" do
      it "shows control_system metadata" do
        control_system = Model::Generator.control_system.save!
        control_system_id = control_system.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: control_system_id).save!

        result = client.get(
          path: "#{Metadata.base_route}/#{control_system_id}",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
        metadata.first[1].parent_id.should eq control_system_id
        metadata.first[1].name.should eq meta.name
      end

      it "filters control_system metadata" do
        control_system = Model::Generator.control_system.save!
        control_system_id = control_system.id.as(String)

        Model::Generator.metadata(parent: control_system_id).save!
        Model::Generator.metadata(name: "special", parent: control_system_id).save!

        result = client.get(
          path: "#{Metadata.base_route}/#{control_system_id}?name=special",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
      end

      it "shows zone metadata" do
        zone = Model::Generator.zone.save!
        zone_id = zone.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

        result = client.get(
          path: "#{Metadata.base_route}/#{zone_id}",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
        metadata.first[1].parent_id.should eq zone_id
        metadata.first[1].name.should eq meta.name
      end

      it "filters zone metadata" do
        zone = Model::Generator.zone.save!
        zone_id = zone.id.as(String)

        Model::Generator.metadata(parent: zone_id).save!
        Model::Generator.metadata(name: "special", parent: zone_id).save!

        result = client.get(
          path: "#{Metadata.base_route}/#{zone_id}?name=special",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
      end
    end

    describe "GET /metadata/:id/history" do
      it "renders the version history for a single metadata document" do
        changes = [0, 1, 2, 3].map { |i| JSON::Any.new({"test" => JSON::Any.new(i.to_i64)}) }
        name = random_name
        metadata = Model::Generator.metadata(name: name)
        metadata.details = changes.first
        metadata.save!

        changes[1..].each_with_index(offset: 1) do |detail, i|
          Timecop.freeze(i.seconds.from_now) do
            metadata.details = detail
            metadata.save!
          end
        end

        result = client.get(
          path: File.join(Metadata.base_route, metadata.parent_id.as(String), "history"),
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        history = Hash(String, Array(Model::Metadata::Interface)).from_json(result.body)
        history.has_key?(name).should be_true
        history[name].map(&.details.as_h["test"]).should eq [3, 2, 1, 0]
      end
    end

    describe "scopes" do
      context "read" do
        scope_name = "metadata"

        it "allows access to show" do
          _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :read)])

          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          3.times do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            Model::Generator.metadata(parent: child.id).save!
          end

          result = client.get(
            path: "#{Metadata.base_route}/#{parent_id}/children",
            headers: scoped_headers,
          )
          result.status_code.should eq 200
          Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
            .from_json(result.body)
            .tap(&.size.should eq(3))
            .count(&.[:metadata].empty?.!)
            .should eq 3

          parent.destroy
        end

        it "should not allow access to delete" do
          _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :read)])

          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          3.times do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            Model::Generator.metadata(parent: child.id).save!
          end

          id = parent.id.as(String)

          result = client.delete(
            path: "#{Metadata.base_route}/#{id}",
            headers: scoped_headers,
          )
          result.status_code.should eq 403
        end
      end

      context "write" do
        scope_name = "metadata"

        it "should allow access to update" do
          _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :write)])

          parent = Model::Generator.zone.save!
          meta = Model::Metadata::Interface.new(
            name: "test",
            description: "",
            details: JSON.parse(%({"hello":"world","bye":"friends"})),
            parent_id: nil,
            editors: Set(String).new,
          )

          parent_id = parent.id.as(String)
          path = "#{Metadata.base_route}/#{parent_id}"

          result = client.put(
            path: path,
            body: meta.to_json,
            headers: scoped_headers,
          )

          new_metadata = Model::Metadata::Interface.from_json(result.body)
          found = Model::Metadata.for(parent_id, meta.name).first
          found.name.should eq new_metadata.name
        end

        it "should not allow access to show" do
          _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :write)])

          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          3.times do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            Model::Generator.metadata(parent: child.id).save!
          end

          result = client.get(
            path: "#{Metadata.base_route}/#{parent_id}/children",
            headers: scoped_headers,
          )
          result.status_code.should eq 403
        end
      end

      it "checks that guests can read metadata" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("guest", PlaceOS::Model::UserJWT::Scope::Access::Read)])

        zone = Model::Generator.zone.save!
        zone_id = zone.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

        result = client.get(
          path: "#{Metadata.base_route}/#{zone_id}",
          headers: scoped_headers,
        )

        result.status_code.should eq 200
        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
        metadata.values.first.parent_id.should eq zone_id
        metadata.values.first.name.should eq meta.name
      end

      it "checks that guests cannot write metadata" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("guest", PlaceOS::Model::UserJWT::Scope::Access::Read)])

        zone = Model::Generator.zone.save!
        zone_id = zone.id.as(String)

        result = client.post(
          path: "#{Metadata.base_route}/#{zone_id}",
          headers: scoped_headers,
        )
        result.success?.should be_false
      end
    end
  end
end
