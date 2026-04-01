require "../helper"

module PlaceOS::Api
  describe Zones do
    Spec.test_404(Zones.base_route, model_name: Model::Zone.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(klass: Model::Zone, controller_klass: Zones)

      it "filters by single parent_id" do
        parent = Model::Generator.zone.save!
        child1 = Model::Generator.zone
        child1.parent_id = parent.id
        child1.save!
        child2 = Model::Generator.zone
        child2.parent_id = parent.id
        child2.save!

        sleep 1.second
        refresh_elastic(Model::Zone.table_name)

        params = HTTP::Params.encode({"parent_id" => parent.id.as(String)})
        path = "#{Zones.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)

        result.success?.should be_true
        zones = Array(Hash(String, JSON::Any)).from_json(result.body)
        zone_ids = zones.map(&.["id"].as_s)
        zone_ids.should contain(child1.id)
        zone_ids.should contain(child2.id)

        parent.destroy
        child1.destroy
        child2.destroy
      end

      it "filters by multiple parent_ids (comma-separated)" do
        parent1 = Model::Generator.zone.save!
        parent2 = Model::Generator.zone.save!
        parent3 = Model::Generator.zone.save!

        child1 = Model::Generator.zone
        child1.parent_id = parent1.id
        child1.save!

        child2 = Model::Generator.zone
        child2.parent_id = parent2.id
        child2.save!

        child3 = Model::Generator.zone
        child3.parent_id = parent3.id
        child3.save!

        sleep 1.second
        refresh_elastic(Model::Zone.table_name)

        # Query for children of parent1 and parent2 (should not include child3)
        parent_ids = "#{parent1.id},#{parent2.id}"
        params = HTTP::Params.encode({"parent_id" => parent_ids})
        path = "#{Zones.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)

        result.success?.should be_true
        zones = Array(Hash(String, JSON::Any)).from_json(result.body)
        zone_ids = zones.map(&.["id"].as_s)
        zone_ids.should contain(child1.id)
        zone_ids.should contain(child2.id)
        zone_ids.should_not contain(child3.id)

        parent1.destroy
        parent2.destroy
        parent3.destroy
        child1.destroy
        child2.destroy
        child3.destroy
      end

      it "gets root zones with parent_id=root" do
        root1 = Model::Generator.zone.save!
        root2 = Model::Generator.zone.save!

        child = Model::Generator.zone
        child.parent_id = root1.id
        child.save!

        sleep 1.second
        refresh_elastic(Model::Zone.table_name)

        params = HTTP::Params.encode({"parent_id" => "root"})
        path = "#{Zones.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)

        result.success?.should be_true
        zones = Array(Hash(String, JSON::Any)).from_json(result.body)
        zone_ids = zones.map(&.["id"].as_s)

        zone_ids.should contain(root1.id)
        zone_ids.should contain(root2.id)
        zone_ids.should_not contain(child.id)

        root1.destroy
        root2.destroy
        child.destroy
      end

      it "includes children_count when requested" do
        parent = Model::Generator.zone.save!

        child1 = Model::Generator.zone
        child1.parent_id = parent.id
        child1.save!

        child2 = Model::Generator.zone
        child2.parent_id = parent.id
        child2.save!

        grandchild = Model::Generator.zone
        grandchild.parent_id = child1.id
        grandchild.save!

        sleep 1.second
        refresh_elastic(Model::Zone.table_name)

        params = HTTP::Params.encode({"parent_id" => parent.id.as(String), "include_children_count" => "true"})
        path = "#{Zones.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)

        result.success?.should be_true
        zones = Array(Hash(String, JSON::Any)).from_json(result.body)

        child1_data = zones.find { |z| z["id"].as_s == child1.id }
        child2_data = zones.find { |z| z["id"].as_s == child2.id }

        child1_data.should_not be_nil
        child2_data.should_not be_nil

        child1_data.not_nil!["children_count"].as_i.should eq 1
        child2_data.not_nil!["children_count"].as_i.should eq 0

        parent.destroy
        child1.destroy
        child2.destroy
        grandchild.destroy
      end

      it "preserves include_children_count across paginated requests" do
        parent = Model::Generator.zone.save!

        children = Array(Model::Zone).new
        5.times do
          child = Model::Generator.zone
          child.parent_id = parent.id
          child.save!
          children << child
        end

        sleep 1.second
        refresh_elastic(Model::Zone.table_name)

        params = HTTP::Params.encode({
          "parent_id"              => parent.id.as(String),
          "include_children_count" => "true",
          "limit"                  => "2",
        })
        path = "#{Zones.base_route}?#{params}"
        result = client.get(path, headers: Spec::Authentication.headers)

        result.success?.should be_true

        link_header = result.headers["Link"]?
        link_header.should_not be_nil
        link_header.not_nil!.should contain("include_children_count=true")

        zones = Array(Hash(String, JSON::Any)).from_json(result.body)
        zones.size.should eq 2
        zones.each do |zone|
          zone["children_count"]?.should_not be_nil
        end

        parent.destroy
        children.each(&.destroy)
      end
    end

    describe "tags", tags: "search" do
      result = client.get(path: "#{Zones.base_route}tags", headers: Spec::Authentication.headers)
      result.success?.should be_true
      list = JSON.parse(result.body)
      list.as_a?.should_not be_nil
      list.as_a.size.should be > 0
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(klass: Model::Zone, controller_klass: Zones)

      it "update" do
        zone = Model::Generator.zone.save!
        original_name = zone.name
        zone.name = random_name

        id = zone.id.as(String)
        path = File.join(Zones.base_route, id)
        result = client.patch(
          path: path,
          body: zone.to_json,
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true
        updated = Model::Zone.from_trusted_json(result.body)

        updated.id.should eq zone.id
        updated.name.should_not eq original_name
        updated.destroy
      end

      it "fails to create if a regular user" do
        org_zone_id = Spec::Authentication.org_zone.id.as(String)
        zone = PlaceOS::Model::Generator.zone
        zone.parent_id = org_zone_id
        result = client.post(
          Zones.base_route,
          body: zone.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end

      it "fails to delete if a concierge user" do
        org_zone_id = Spec::Authentication.org_zone.id.as(String)
        auth_headers = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["concierge"])

        zone = PlaceOS::Model::Generator.zone
        zone.parent_id = org_zone_id
        result = client.post(
          Zones.base_route,
          body: zone.to_json,
          headers: auth_headers
        )
        result.success?.should be_true

        zone = Model::Zone.from_trusted_json result.body
        result = client.delete(
          path: "#{Zones.base_route}#{zone.id}",
          headers: auth_headers,
        )
        result.success?.should be_false
        result.status_code.should eq 403
      end

      it "management user can perform CRUD operations when in the org zone" do
        org_zone_id = Spec::Authentication.org_zone.id.as(String)
        auth_headers = Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])

        zone = PlaceOS::Model::Generator.zone
        zone.parent_id = org_zone_id
        result = client.post(
          Zones.base_route,
          body: zone.to_json,
          headers: auth_headers
        )
        result.success?.should be_true

        zone = Model::Zone.from_trusted_json result.body
        result = client.delete(
          path: "#{Zones.base_route}#{zone.id}",
          headers: auth_headers,
        )
        result.success?.should be_true
      end
    end

    describe "GET /zones/:id/metadata" do
      it "shows zone metadata" do
        zone = Model::Generator.zone.save!
        zone_id = zone.id.as(String)
        meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

        result = client.get(
          path: Zones.base_route + "#{zone_id}/metadata",
          headers: Spec::Authentication.headers,
        )

        metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
        metadata.size.should eq 1
        metadata.first[1].parent_id.should eq zone_id
        metadata.first[1].name.should eq meta.name

        zone.destroy
        meta.destroy
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Zones)
      Spec.test_update_write_scope(Zones)
    end
  end
end
