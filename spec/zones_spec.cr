require "./helper"

module Engine::API
  describe Zones do
    with_server do
      test_404(namespace: Zones::NAMESPACE, model_name: Model::Zone.table_name)

      pending "index" do
        test_base_index(klass: Model::Zone, controller_klass: Zones)
      end

      describe "CRUD operations" do
        test_crd(klass: Model::Zone, controller_klass: Zones)
        it "update" do
          zone = Model::Generator.zone.save!
          original_name = zone.name
          zone.name = Faker::Hacker.noun*2

          id = zone.id.not_nil!
          path = Zones::NAMESPACE[0] + id
          result = curl(
            method: "PATCH",
            path: path,
            body: zone.to_json,
            headers: {"Content-Type" => "application/json"},
          )

          result.success?.should be_true
          updated = Model::Zone.from_json(result.body)

          updated.id.should eq zone.id
          updated.name.should_not eq original_name
        end
      end
    end
  end
end
