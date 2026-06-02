require "../helper"

module PlaceOS::Api
  describe Alerts do
    Spec.test_404(Alerts.base_route, model_name: Model::Alert.table_name, headers: Spec::Authentication.headers, clz: String)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::Alert, Alerts)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::Alert, Alerts)
      Spec.test_crd(Model::Alert, Alerts, sys_admin: false, support: false, groups: ["management"])

      it "allows management users to create alerts" do
        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        alert = PlaceOS::Model::Generator.alert(name: "Test Alert", description: "Test Description", alert_dashboard_id: dashboard.id)
        result = client.post(
          Alerts.base_route,
          body: alert.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])
        )
        result.success?.should be_true
        dashboard.destroy
      end

      it "prevents creating alerts for dashboards in different authorities" do
        # unique domain — `other.example.com` is also used by uploads_spec, and a
        # hardcoded domain shared across specs collides within a suite run
        other_authority = PlaceOS::Model::Generator.authority("other-#{random_name}.example.com")
        other_authority.save!

        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description", authority_id: other_authority.id)
        dashboard.save!

        alert = PlaceOS::Model::Generator.alert(name: "Test Alert", description: "Test Description", alert_dashboard_id: dashboard.id)

        result = client.post(
          Alerts.base_route,
          body: alert.to_json,
          headers: Spec::Authentication.headers(sys_admin: false, support: false, groups: ["management"])
        )
        result.status_code.should eq 403

        dashboard.destroy
        other_authority.destroy
      end
    end

    describe "filtering", tags: "search" do
      it "filters by severity" do
        # ensure the enum columns are mapped before search-ingest indexes the new
        # alerts (the pinned search-ingest image doesn't map enums; see helper)
        ensure_keyword_mapping(Model::Alert.table_name, ["severity", "alert_type"])

        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        high_alert = PlaceOS::Model::Generator.alert(name: "High Alert", description: "High Priority Alert", alert_dashboard_id: dashboard.id, severity: PlaceOS::Model::Alert::Severity::HIGH)
        high_alert.save!

        low_alert = PlaceOS::Model::Generator.alert(name: "Low Alert", description: "Low Priority Alert", alert_dashboard_id: dashboard.id, severity: PlaceOS::Model::Alert::Severity::LOW)
        low_alert.save!

        # make the new alerts searchable, then scope to this test's dashboard so the
        # count is deterministic regardless of other alerts in the shared ES index
        sleep 1.second
        refresh_elastic(Model::Alert.table_name)

        params = HTTP::Params.encode({"severity" => "HIGH", "alert_dashboard_id" => dashboard.id.as(String)})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        # the API serializes the enum as its lower-cased member name
        alerts.first["severity"].as_s.should eq "high"
      end

      it "filters by alert type" do
        # ensure the enum columns are mapped before search-ingest indexes the new
        # alerts (the pinned search-ingest image doesn't map enums; see helper)
        ensure_keyword_mapping(Model::Alert.table_name, ["severity", "alert_type"])

        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        threshold_alert = PlaceOS::Model::Generator.alert(name: "Threshold Alert", description: "Threshold Alert", alert_dashboard_id: dashboard.id, alert_type: PlaceOS::Model::Alert::AlertType::THRESHOLD)
        threshold_alert.save!

        status_alert = PlaceOS::Model::Generator.alert(name: "Status Alert", description: "Status Alert", alert_dashboard_id: dashboard.id, alert_type: PlaceOS::Model::Alert::AlertType::STATUS)
        status_alert.save!

        # make the new alerts searchable, then scope to this test's dashboard so the
        # count is deterministic regardless of other alerts in the shared ES index
        sleep 1.second
        refresh_elastic(Model::Alert.table_name)

        params = HTTP::Params.encode({"alert_type" => "THRESHOLD", "alert_dashboard_id" => dashboard.id.as(String)})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        # the API serializes the enum as its lower-cased member name
        alerts.first["alert_type"].as_s.should eq "threshold"
      end
    end
  end
end
