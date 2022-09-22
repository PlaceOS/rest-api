require "../helper"

module PlaceOS::Api
  describe Zones do
    Spec.test_404(Zones.base_route, model_name: Model::Zone.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(klass: Model::Zone, controller_klass: Zones)
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
