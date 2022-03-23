require "../helper"
require "timecop"

module PlaceOS::Api
  describe Metadata do
    _authenticated_user, authorization_header = authentication
    base = Metadata::NAMESPACE[0]

    with_server do
      describe "/metadata/:id/children/" do
        it "shows zone children metadata" do
          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          3.times do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            Model::Generator.metadata(parent: child.id).save!
          end

          result = curl(
            method: "GET",
            path: "#{base}/#{parent_id}/children",
            headers: authorization_header,
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

          result = curl(
            method: "GET",
            path: "#{base}/#{parent_id}/children?name=special",
            headers: authorization_header,
          )

          Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
            .from_json(result.body)
            .count(&.[:metadata].empty?.!)
            .should eq 1

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
          path = "#{base}/#{parent_id}"

          result = curl(
            method: "PUT",
            path: path,
            body: meta.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 201

          new_metadata = Model::Metadata::Interface.from_json(result.body)
          found = Model::Metadata.for(parent.id.as(String), meta.name).first
          found.name.should eq new_metadata.name
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
          path = "#{base}/#{parent_id}"

          result = curl(
            method: "PUT",
            path: path,
            body: meta.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 201

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

          result = curl(
            method: "PUT",
            path: path,
            body: updated_meta.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200

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

          result = curl(
            method: "GET",
            path: "#{base}/#{control_system_id}",
            headers: authorization_header,
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

          result = curl(
            method: "GET",
            path: "#{base}/#{control_system_id}?name=special",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
        end

        it "shows zone metadata" do
          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)
          meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{zone_id}",
            headers: authorization_header,
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

          result = curl(
            method: "GET",
            path: "#{base}/#{zone_id}?name=special",
            headers: authorization_header,
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

          result = curl(
            method: "GET",
            path: File.join(base, metadata.parent_id.as(String), "history"),
            headers: authorization_header,
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
            _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :read)])

            parent = Model::Generator.zone.save!
            parent_id = parent.id.as(String)

            3.times do
              child = Model::Generator.zone
              child.parent_id = parent_id
              child.save!
              Model::Generator.metadata(parent: child.id).save!
            end

            result = curl(
              method: "GET",
              path: "#{base}/#{parent_id}/children",
              headers: scoped_authorization_header,
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
            _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :read)])

            parent = Model::Generator.zone.save!
            parent_id = parent.id.as(String)

            3.times do
              child = Model::Generator.zone
              child.parent_id = parent_id
              child.save!
              Model::Generator.metadata(parent: child.id).save!
            end

            id = parent.id.as(String)

            result = curl(
              method: "DELETE",
              path: "#{base}/#{id}",
              headers: scoped_authorization_header,
            )
            result.status_code.should eq 403
          end
        end

        context "write" do
          scope_name = "metadata"

          it "should allow access to update" do
            _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :write)])

            parent = Model::Generator.zone.save!
            meta = Model::Metadata::Interface.new(
              name: "test",
              description: "",
              details: JSON.parse(%({"hello":"world","bye":"friends"})),
              parent_id: nil,
              editors: Set(String).new,
            )

            parent_id = parent.id.as(String)
            path = "#{base}/#{parent_id}"

            result = curl(
              method: "PUT",
              path: path,
              body: meta.to_json,
              headers: scoped_authorization_header.merge({"Content-Type" => "application/json"}),
            )

            new_metadata = Model::Metadata::Interface.from_json(result.body)
            found = Model::Metadata.for(parent_id, meta.name).first
            found.name.should eq new_metadata.name
          end

          it "should not allow access to show" do
            _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new(scope_name, :write)])

            parent = Model::Generator.zone.save!
            parent_id = parent.id.as(String)

            3.times do
              child = Model::Generator.zone
              child.parent_id = parent_id
              child.save!
              Model::Generator.metadata(parent: child.id).save!
            end

            result = curl(
              method: "GET",
              path: "#{base}/#{parent_id}/children",
              headers: scoped_authorization_header,
            )
            result.status_code.should eq 403
          end
        end

        it "checks that guests can read metadata" do
          _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("guest", PlaceOS::Model::UserJWT::Scope::Access::Read)])

          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)
          meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{zone_id}",
            headers: scoped_authorization_header,
          )

          result.status_code.should eq 200
          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
          metadata.values.first.parent_id.should eq zone_id
          metadata.values.first.name.should eq meta.name
        end

        it "checks that guests cannot write metadata" do
          _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("guest", PlaceOS::Model::UserJWT::Scope::Access::Read)])

          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)

          result = curl(
            method: "POST",
            path: "#{base}/#{zone_id}",
            headers: scoped_authorization_header,
          )
          result.success?.should be_false
        end
      end
    end
  end
end
