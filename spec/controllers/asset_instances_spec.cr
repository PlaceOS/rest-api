require "../helper"
require "timecop"

module PlaceOS::Api
  describe AssetInstances do
    Spec.test_404(
      AssetInstances.base_route,
      model_name: Model::AssetInstance.table_name,
      headers: Spec::Authentication.headers,
    )

    describe "index", tags: "search" do
      Spec.test_base_index(klass: Model::AssetInstance, controller_klass: PlaceOS::Api::AssetInstances)
    end

    describe "CRUD operations", tags: "crud" do
      it "create" do
        asset_instance = Model::Generator.asset_instance.save!
        body = asset_instance.to_json

        result = client.post(
          path: AssetInstances.base_route,
          body: body,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 201
        body = result.body.not_nil!
        Model::AssetInstance.find(JSON.parse(body)["id"].as_s).try &.destroy
      end

      it "show" do
        asset_instance = Model::Generator.asset_instance.save!
        path = AssetInstances.base_route + asset_instance.id.not_nil!

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers,
        )

        fetched = Model::AssetInstance.from_trusted_json(result.body)
        fetched.id.should eq asset_instance.id
      end

      it "update" do
        asset_instance = Model::Generator.asset_instance.save!

        id = asset_instance.id.not_nil!
        path = File.join(AssetInstances.base_route, id)

        result = client.patch(
          path: path,
          body: {approval: true}.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::AssetInstance.from_trusted_json(result.body)

        updated.id.should eq id
        updated.approval.should be_true
        updated.destroy
      end

      it "destroy" do
        model = PlaceOS::Model::Generator.asset_instance.save!
        model.persisted?.should be_true

        id = model.id.not_nil!
        path = File.join(AssetInstances.base_route, id)

        result = client.delete(path: path, headers: Spec::Authentication.headers)
        result.success?.should eq true

        Model::AssetInstance.find(id.as(String)).should be_nil
      end
    end
  end
end
