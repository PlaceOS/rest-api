require "../helper"
require "timecop"

module PlaceOS::Api
  describe AssetInstances do
    base = AssetInstances::NAMESPACE[0]

    with_server do
      test_404(
        base.gsub(/:asset_id/, "asset-#{Random.rand(9999)}"),
        model_name: Model::AssetInstance.table_name,
        headers: authorization_header,
      )

      describe "CRUD operations", tags: "crud" do
        it "create" do
          asset = Model::Generator.asset.save!
          asset_instance = Model::Generator.asset_instance
          asset_instance.asset = asset
          body = asset_instance.to_json

          path = base.gsub(/:asset_id/, asset.id)
          result = curl(
            method: "POST",
            path: path,
            body: body,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 201
          body = result.body.not_nil!
          Model::AssetInstance.find(JSON.parse(body)["id"].as_s).try &.destroy
        end

        it "show" do
          asset = Model::Generator.asset.save!
          asset_instance = Model::Generator.asset_instance
          asset_instance.asset = asset
          asset_instance.save!

          path = base.gsub(/:asset_id/, asset.id) + asset_instance.id.not_nil!

          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )

          fetched = Model::AssetInstance.from_trusted_json(result.body)
          fetched.id.should eq asset_instance.id
        end

        it "update" do
          asset_instance = Model::Generator.asset_instance
          asset = Model::Generator.asset.save!
          asset_instance.asset = asset
          asset_instance.save!

          id = asset_instance.id.not_nil!
          path = base.gsub(/:asset_id/, asset.id) + id

          result = curl(
            method: "PATCH",
            path: path,
            body: {approval: true}.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::AssetInstance.from_trusted_json(result.body)

          updated.id.should eq asset_instance.id
          updated.approval.should be_true
          updated.destroy
        end

        it "destroy" do
          model = PlaceOS::Model::Generator.asset_instance
          asset = Model::Generator.asset.save!
          model.asset = asset
          model.save!

          model.persisted?.should be_true

          id = model.id.not_nil!
          path = base.gsub(/:asset_id/, asset.id) + id

          result = curl(method: "DELETE", path: path, headers: authorization_header)
          result.status_code.should eq 200

          Model::AssetInstance.find(id.as(String)).should be_nil
        end
      end
    end
  end
end
