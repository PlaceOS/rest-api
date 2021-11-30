require "../helper"
require "timecop"

module PlaceOS::Api
  describe AssetInstances do
    base = AssetInstances::NAMESPACE[0]

    with_server do
      test_404(
        base.gsub(/:zone_id/, "zone-#{Random.rand(9999)}"),
        model_name: Model::AssetInstance.table_name,
        headers: authorization_header,
      )

      describe "index", tags: "search" do
        pending "as_of query" do
          zone = Model::Generator.zone.save!
          path = base.gsub(/:zone_id/, zone.id)
          inst1 = Model::Generator.asset_instance
          Timecop.freeze(2.days.ago) do
            inst1.save!
          end
          inst1.persisted?.should be_true

          inst2 = Model::Generator.asset_instance

          inst2.persisted?.should be_true

          refresh_elastic(Model::AssetInstance.table_name)

          params = HTTP::Params.encode({"as_of" => (inst1.updated_at.try &.to_unix).to_s})
          path = "#{path}?#{params}"
          correct_response = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            contains_correct = results.any?(inst1.id)
            contains_incorrect = results.any?(inst2.id)

            !results.empty? && contains_correct && !contains_incorrect
          end

          correct_response.should be_true
        end
      end

      describe "CRUD operations", tags: "crud" do
        it "create" do
          zone = Model::Generator.zone.save!
          asset_instance = Model::Generator.asset_instance
          asset_instance.zone = zone
          body = asset_instance.to_json

          path = base.gsub(/:zone_id/, zone.id)
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

        pending "show" do
        end

        it "update" do
          asset_instance = Model::Generator.asset_instance
          zone = Model::Generator.zone.save!
          asset_instance.zone = zone
          asset_instance.save!

          id = asset_instance.id.not_nil!
          path = base.gsub(/:zone_id/, zone.id) + id

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
          zone = Model::Generator.zone.save!
          model.zone = zone
          model.save!

          model.persisted?.should be_true

          id = model.id.not_nil!
          path = base.gsub(/:zone_id/, zone.id) + id

          result = curl(method: "DELETE", path: path, headers: authorization_header)
          result.status_code.should eq 200

          Model::AssetInstance.find(id.as(String)).should be_nil
        end
      end
    end
  end
end
