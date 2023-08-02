require "../helper"

module PlaceOS::Api
  describe AssetPurchaseOrders do
    Spec.test_404(AssetPurchaseOrders.base_route, model_name: Model::AssetPurchaseOrder.table_name, headers: Spec::Authentication.headers, clz: Int64)

    describe "index", tags: "search" do
      it "queries AssetPurchaseOrder", tags: "search" do
        _, headers = Spec::Authentication.authentication
        doc = PlaceOS::Model::Generator.asset_purchase_order
        purchase_order_number = random_name
        doc.purchase_order_number = purchase_order_number
        doc.save!

        refresh_elastic(Model::AssetPurchaseOrder.table_name)

        doc.persisted?.should be_true
        params = HTTP::Params.encode({"q" => purchase_order_number})
        path = "#{AssetPurchaseOrders.base_route.rstrip('/')}?#{params}"

        found = until_expected("GET", path, headers) do |response|
          Array(Hash(String, JSON::Any))
            .from_json(response.body)
            .map(&.["id"].to_s)
            .any?(doc.id)
        end
        found.should be_true
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AssetPurchaseOrder, AssetPurchaseOrders)
      Spec.test_crd(Model::AssetPurchaseOrder, AssetPurchaseOrders, sys_admin: false, support: false, groups: ["management"])
      Spec.test_crd(Model::AssetPurchaseOrder, AssetPurchaseOrders, sys_admin: false, support: false, groups: ["concierge"])

      it "fails to create if a regular user" do
        body = PlaceOS::Model::Generator.asset_purchase_order.to_json
        result = client.post(
          AssetPurchaseOrders.base_route,
          body: body,
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )
        result.status_code.should eq 403
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(AssetPurchaseOrders)
    end
  end
end
