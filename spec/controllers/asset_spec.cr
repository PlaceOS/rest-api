require "../helper"

module PlaceOS::Api
  describe Assets do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Assets::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Asset.table_name, headers: authorization_header)

      pending "index", tags: "searchh" do
        test_base_index(klass: Model::Asset, controller_klass: Assets)
      end

      describe "/:id/instances" do
        it "lists instances for an Asset" do
          asset = Model::Generator.asset.save!
          instances = Array(Model::AssetInstance).new(size: 3) { Model::Generator.asset_instance(asset).save! }

          response = curl(
            method: "GET",
            path: File.join(base, asset.id.not_nil!, "instances"),
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          # Can't use from_json directly on the model as `id` will not be parsed
          result = Array(JSON::Any).from_json(response.body).map { |d| Model::AssetInstance.from_trusted_json(d.to_json) }

          result.all? { |i| i.asset_id == asset.id }.should be_true
          instances.compact_map(&.id).sort!.should eq result.compact_map(&.id).sort!
        end
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Asset, controller_klass: Assets)
      end
      it "update" do
        asset = Model::Generator.asset.save!
        original_name = asset.name

        asset.name = UUID.random.to_s

        id = asset.id.as(String)
        path = base + id
        result = curl(
          method: "PATCH",
          path: path,
          body: asset.to_json,
          headers: authorization_header.merge({"Content-Type" => "application/json"}),
        )

        result.status_code.should eq 200
        updated = Model::Asset.from_trusted_json(result.body)

        updated.id.should eq asset.id
        updated.name.should_not eq original_name
        updated.destroy
      end

      # describe "show" do
      #   it "includes asset_instances with truthy `instances`" do
      #     asset = Model::Generator.asset.save!
      #     asset_instance = Model::Generator.asset_instance(asset).save!
      #     asset_instance_id = asset_instance.id.as(String)

      #     params = HTTP::Params{"instances" => "true"}
      #     path = "#{base}#{asset.id}?#{params}"

      #     result = curl(
      #       method: "GET",
      #       path: path,
      #       headers: authorization_header.merge({"Content-Type" => "application/json"}),
      #     )

      #     response = JSON.parse(result.body)
      #     response["asset_instances"].as_a?.try &.first?.try &.["id"].to_s.should eq asset_instance_id
      #   end
      # end
    end

    describe "scopes" do
      test_controller_scope(Assets)
      test_update_write_scope(Assets)
    end
  end
end
