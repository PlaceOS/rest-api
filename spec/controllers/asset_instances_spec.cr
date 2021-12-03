require "../helper"
require "timecop"

module PlaceOS::Api
  describe AssetInstances do
    base = AssetInstances::NAMESPACE[0]

    with_server do
      test_404(
        base,
        model_name: Model::AssetInstance.table_name,
        headers: authorization_header,
      )

      describe "index", tags: "search" do
        test_base_index(klass: Model::AssetInstance, controller_klass: AssetInstances)
      end

      describe "CRUD operations", tags: "crud" do
        it "create" do
          asset_instance = Model::Generator.asset_instance.save!
          body = asset_instance.to_json

          result = curl(
            method: "POST",
            path: base,
            body: body,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 201
          body = result.body.not_nil!
          Model::AssetInstance.find(JSON.parse(body)["id"].as_s).try &.destroy
        end

        it "show" do
          asset_instance = Model::Generator.asset_instance.save!
          path = base + asset_instance.id.not_nil!

          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          fetched = Model::AssetInstance.from_trusted_json(result.body)
          fetched.id.should eq asset_instance.id
        end

        it "update" do
          asset_instance = Model::Generator.asset_instance.save!

          id = asset_instance.id.not_nil!
          path = base + id

          result = curl(
            method: "PATCH",
            path: path,
            body: {approval: true}.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
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
          path = base + id

          result = curl(method: "DELETE", path: path, headers: authorization_header)
          result.status_code.should eq 200

          Model::AssetInstance.find(id.as(String)).should be_nil
        end
      end
    end
  end
end
