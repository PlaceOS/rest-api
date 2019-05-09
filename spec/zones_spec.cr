require "./helper"

module Engine::API
  describe Zones do
    with_server do
      test_404(namespace: Zones::NAMESPACE, model_name: Model::Zone.table_name)
      pending "index"
      describe "CRUD operations" do
        test_crd(klass: Model::Zone, controller_klass: Zones)
        pending "update" do
          zone = Model::Generator.zone.save!
          zone.name = Faker::Hacker.name

          id = zone.id.not_nil!
          path = Zones::NAMESPACE[0] + id
          result = curl(
            method: "PATCH",
            path: path,
            body: zone.to_json,
            headers: {"Content-Type" => "application/json"},
          )

          result.success?.should be_true
          updated = Model::Zone.from_trusted_json(result.body)
          updated.attributes.should eq zone.attributes
        end
      end
    end
  end
end
