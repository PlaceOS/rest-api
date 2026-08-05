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
        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        high_alert = PlaceOS::Model::Generator.alert(name: "High Alert", description: "High Priority Alert", alert_dashboard_id: dashboard.id, severity: PlaceOS::Model::Alert::Severity::HIGH)
        high_alert.save!

        low_alert = PlaceOS::Model::Generator.alert(name: "Low Alert", description: "Low Priority Alert", alert_dashboard_id: dashboard.id, severity: PlaceOS::Model::Alert::Severity::LOW)
        low_alert.save!

        # scope to this test's dashboard so the count is deterministic
        # regardless of alerts created by other tests
        params = HTTP::Params.encode({"severity" => "HIGH", "alert_dashboard_id" => dashboard.id.as(String)})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        alerts.first["id"].as_s.should eq high_alert.id
        # the API serializes the enum as its lower-cased member name
        alerts.first["severity"].as_s.should eq "high"
      end

      it "filters by alert type" do
        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        threshold_alert = PlaceOS::Model::Generator.alert(name: "Threshold Alert", description: "Threshold Alert", alert_dashboard_id: dashboard.id, alert_type: PlaceOS::Model::Alert::AlertType::THRESHOLD)
        threshold_alert.save!

        status_alert = PlaceOS::Model::Generator.alert(name: "Status Alert", description: "Status Alert", alert_dashboard_id: dashboard.id, alert_type: PlaceOS::Model::Alert::AlertType::STATUS)
        status_alert.save!

        params = HTTP::Params.encode({"alert_type" => "THRESHOLD", "alert_dashboard_id" => dashboard.id.as(String)})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        alerts.first["id"].as_s.should eq threshold_alert.id
        # the API serializes the enum as its lower-cased member name
        alerts.first["alert_type"].as_s.should eq "threshold"
      end

      it "filters by enabled status, including enabled=false" do
        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        enabled_alert = PlaceOS::Model::Generator.alert(name: "Enabled Alert", description: "Enabled Alert", alert_dashboard_id: dashboard.id, enabled: true)
        enabled_alert.save!

        disabled_alert = PlaceOS::Model::Generator.alert(name: "Disabled Alert", description: "Disabled Alert", alert_dashboard_id: dashboard.id, enabled: false)
        disabled_alert.save!

        # enabled=false previously matched everything (the Elasticsearch-era
        # filter was skipped for falsy values) — it must now filter
        params = HTTP::Params.encode({"enabled" => "false", "alert_dashboard_id" => dashboard.id.as(String)})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        alerts.first["id"].as_s.should eq disabled_alert.id
        alerts.first["enabled"].as_bool.should be_false

        params = HTTP::Params.encode({"enabled" => "true", "alert_dashboard_id" => dashboard.id.as(String)})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        alerts.first["id"].as_s.should eq enabled_alert.id
        alerts.first["enabled"].as_bool.should be_true
      end

      it "combines q with filters" do
        dashboard = PlaceOS::Model::Generator.alert_dashboard(name: "Test Dashboard", description: "Test Description")
        dashboard.save!

        name = random_name
        named_alert = PlaceOS::Model::Generator.alert(name: name, description: "Named Alert", alert_dashboard_id: dashboard.id, severity: PlaceOS::Model::Alert::Severity::CRITICAL)
        named_alert.save!

        other_alert = PlaceOS::Model::Generator.alert(name: "Other Alert", description: "Other Alert", alert_dashboard_id: dashboard.id, severity: PlaceOS::Model::Alert::Severity::CRITICAL)
        other_alert.save!

        params = HTTP::Params.encode({
          "q"                  => name,
          "severity"           => "critical",
          "alert_dashboard_id" => dashboard.id.as(String),
        })
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        alerts = Array(Hash(String, JSON::Any)).from_json(result.body)
        alerts.size.should eq 1
        alerts.first["id"].as_s.should eq named_alert.id
      end
    end

    describe "non-support scoping", tags: "search" do
      it "returns alerts across all of the authority's dashboards" do
        # two dashboards in the caller's authority (generator defaults to the
        # localhost authority the test user belongs to), one alert on each —
        # the Elasticsearch version ANDed the dashboard ids and returned
        # nothing for authorities with more than one dashboard; this pins the
        # IN() semantics
        dashboard_one = PlaceOS::Model::Generator.alert_dashboard(name: "Scoped Dashboard One", description: "Test Description")
        dashboard_one.save!
        dashboard_two = PlaceOS::Model::Generator.alert_dashboard(name: "Scoped Dashboard Two", description: "Test Description")
        dashboard_two.save!

        alert_one = PlaceOS::Model::Generator.alert(name: "Scoped Alert One", description: "Test", alert_dashboard_id: dashboard_one.id)
        alert_one.save!
        alert_two = PlaceOS::Model::Generator.alert(name: "Scoped Alert Two", description: "Test", alert_dashboard_id: dashboard_two.id)
        alert_two.save!

        params = HTTP::Params.encode({"limit" => "1000"})
        result = client.get(
          "#{Alerts.base_route}?#{params}",
          headers: Spec::Authentication.headers(sys_admin: false, support: false)
        )

        result.success?.should be_true
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(alert_one.id)
        ids.should contain(alert_two.id)
      end
    end
  end
end
