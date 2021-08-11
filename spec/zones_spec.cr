require "./helper"

module PlaceOS::Api
  describe Zones do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Zones::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Zone.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        test_base_index(klass: Model::Zone, controller_klass: Zones)
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Zone, controller_klass: Zones)
        it "update" do
          zone = Model::Generator.zone.save!
          original_name = zone.name
          zone.name = UUID.random.to_s

          id = zone.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: zone.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.success?.should be_true
          updated = Model::Zone.from_trusted_json(result.body)

          updated.id.should eq zone.id
          updated.name.should_not eq original_name
          updated.destroy
        end
      end

      describe "/:id/metadata" do
        it "shows zone metadata" do
          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)
          meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

          result = curl(
            method: "GET",
            path: base + "#{zone_id}/metadata",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          puts metadata
          metadata.size.should eq 1
          metadata.first[1].parent_id.should eq zone_id
          metadata.first[1].name.should eq meta.name

          zone.destroy
          meta.destroy
        end
      end
    end
  end
end
