require "../helper"

module PlaceOS::Api
  describe AlertDashboards do
    Spec.test_404(AlertDashboards.base_route, model_name: Model::AlertDashboard.table_name, headers: Spec::Authentication.headers, clz: String)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::AlertDashboard, AlertDashboards)

      it "filters by authority_id" do
        other_authority = PlaceOS::Model::Generator.authority("other-#{random_name}.example.com")
        other_authority.save!

        other_dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Other Authority Dashboard", description: "Test Description", authority_id: other_authority.id)
        other_dashboard.save!

        local_dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Local Dashboard", description: "Test Description")
        local_dashboard.save!

        params = HTTP::Params.encode({"authority_id" => other_authority.id.as(String)})
        result = client.get(
          "#{AlertDashboards.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        dashboards = Array(Hash(String, JSON::Any)).from_json(result.body)
        ids = dashboards.map(&.["id"].as_s)
        ids.should contain(other_dashboard.id)
        ids.should_not contain(local_dashboard.id)
        dashboards.each &.["authority_id"].as_s.should eq other_authority.id

        other_dashboard.destroy
        local_dashboard.destroy
        other_authority.destroy
      end

      it "limits non-support users to their own authority's dashboards" do
        other_authority = PlaceOS::Model::Generator.authority("other-#{random_name}.example.com")
        other_authority.save!

        foreign_dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Foreign Dashboard", description: "Test Description", authority_id: other_authority.id)
        foreign_dashboard.save!

        # generator defaults to the localhost authority the test user belongs to
        own_dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Own Dashboard", description: "Test Description")
        own_dashboard.save!

        params = HTTP::Params.encode({"limit" => "1000"})
        result = client.get(
          "#{AlertDashboards.base_route}?#{params}",
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )

        result.success?.should be_true
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(own_dashboard.id)
        ids.should_not contain(foreign_dashboard.id)

        foreign_dashboard.destroy
        own_dashboard.destroy
        other_authority.destroy
      end
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
