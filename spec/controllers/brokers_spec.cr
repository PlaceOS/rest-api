require "../helper"

module PlaceOS::Api
  describe Brokers do
    _, authorization_header = authentication

    Specs.test_404(Brokers.base_route, model_name: Model::Broker.table_name, headers: authorization_header)

    describe "index", tags: "search" do
      Specs.test_base_index(klass: Model::Broker, controller_klass: Brokers)
    end

    describe "CRUD operations", tags: "crud" do
      Specs.test_crd(Model::Broker, Brokers)

      it "update" do
        broker = Model::Generator.broker.save!
        original_name = broker.name
        broker.name = random_name

        id = broker.id.as(String)
        path = File.join(Brokers.base_route, id)
        result = client.patch(
          path: path,
          body: broker.changed_attributes.to_json,
          headers: authorization_header,
        )

        result.status_code.should eq 200
        updated = Model::Broker.from_trusted_json(result.body)

        updated.id.should eq broker.id
        updated.name.should_not eq original_name
      end
    end

    describe "scopes" do
      Specs.test_update_write_scope(Brokers)
      Specs.test_controller_scope(Brokers)
    end
  end
end
