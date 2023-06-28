require "../helper"

module PlaceOS::Api
  describe Assets do
    Spec.test_404(Assets.base_route, model_name: Model::Asset.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      it "queries Asset", tags: "search" do
        _, headers = Spec::Authentication.authentication
        doc = PlaceOS::Model::Generator.asset
        identifier = random_name
        doc.identifier = identifier
        doc.save!

        refresh_elastic(Model::Asset.table_name)
        doc.persisted?.should be_true

        # search for the asset directly
        params = HTTP::Params.encode({"q" => identifier})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        found = until_expected("GET", path, headers) do |response|
          Array(Hash(String, JSON::Any))
            .from_json(response.body)
            .map(&.["id"].to_s)
            .any?(doc.id)
        end
        found.should be_true

        # don't use until expected once the doc is indexed
        client = ActionController::SpecHelper.client

        # search for asset using the asset type name
        type_name = doc.asset_type.not_nil!.name
        params = HTTP::Params.encode({"q" => type_name})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        response = client.exec(method: "GET", path: path, headers: headers)
        found = Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map(&.["id"].to_s)
          .any?(doc.id)
        found.should be_true

        # search for something else
        params = HTTP::Params.encode({"q" => %("steveavtd")})
        path = "#{Assets.base_route.rstrip('/')}?#{params}"
        response = client.exec(method: "GET", path: path, headers: headers)
        found = Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map(&.["id"].to_s)
          .any?(doc.id)
        found.should be_false
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::Asset, Assets)
    end

    describe "scopes" do
      Spec.test_controller_scope(Assets)
    end
  end
end
