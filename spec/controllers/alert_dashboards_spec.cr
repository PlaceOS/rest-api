require "../helper"

module PlaceOS::Api
  describe AlertDashboards do
    Spec.test_404(AlertDashboards.base_route, model_name: Model::AlertDashboard.table_name, headers: Spec::Authentication.headers, clz: String)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AlertDashboard, AlertDashboards)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::AlertDashboard, AlertDashboards)
      Spec.test_crd(Model::AlertDashboard, AlertDashboards, sys_admin: false, support: false, groups: ["management"])

      it "allows management users to create alert dashboards" do
        dashboard_data = {
          "name"        => "Test Dashboard",
          "description" => "Test Description",
        }
        result = client.post(
          AlertDashboards.base_route,
          body: dashboard_data.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])
        )
        result.success?.should be_true
      end
    end

    describe "GET /alert_dashboards/:id/alerts" do
      it "shows dashboard alerts" do
        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!
        dashboard_id = dashboard.id.as(String)

        alert = PlaceOS::Model::Generator.alert(name: "Test Alert", description: "Test Description", alert_dashboard_id: dashboard_id)
        alert.save!

        result = client.get(
          path: AlertDashboards.base_route + "#{dashboard_id}/alerts",
          headers: Spec::Authentication.headers,
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        alerts.first["id"].as_s.should eq alert.id

        dashboard.destroy
        alert.destroy
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(AlertDashboards)
      Spec.test_update_write_scope(AlertDashboards)
    end
  end
end
