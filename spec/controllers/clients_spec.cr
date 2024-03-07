require "../helper"

module PlaceOS::Api
  describe Clients do
    Spec.test_404(Clients.base_route, model_name: Model::Client.table_name, headers: Spec::Authentication.headers)

    describe "CRUD operations", tags: "crud" do
      it "create" do
        Model::Client.clear
        body = PlaceOS::Model::Generator.client.to_json
        result = client.post(
          Clients.base_route,
          body: body,
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq 201
        response_model = Model::Client.from_trusted_json(result.body)
        response_model.destroy
      end

      it "update" do
        Model::Client.clear
        model = Model::Generator.client.save!
        original_name = model.name

        model.name = random_name

        id = model.id.as(String)
        path = File.join(Clients.base_route, id)
        result = client.patch(
          path: path,
          body: model.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::Client.from_trusted_json(result.body)

        updated.id.should eq model.id
        updated.name.should_not eq original_name
        updated.destroy
      end

      it "show" do
        Model::Client.clear
        model = PlaceOS::Model::Generator.client.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = client.get(
          path: File.join(Clients.base_route, id.to_s),
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        response_model = Model::Client.from_trusted_json(result.body)
        response_model.id.should eq id

        model.destroy
      end

      it "destroy" do
        Model::Client.clear
        model = PlaceOS::Model::Generator.client.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = client.delete(
          path: File.join(Clients.base_route, id.to_s),
          headers: Spec::Authentication.headers
        )

        result.success?.should eq true
        Model::Client.find?(id).should be_nil
      end
    end
  end
end
