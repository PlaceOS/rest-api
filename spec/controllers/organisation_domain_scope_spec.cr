require "../helper"

private def domain_scope_get(path, user)
  client.get(path, headers: PlaceOS::Api::Spec::Tenancy.headers(user))
end

module PlaceOS::Api
  describe "organisation-selected domain resources" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    build = -> { fixture = Spec::Tenancy.build }
    global_storages = [] of String

    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      unless global_storages.empty?
        Model::Upload.where(storage_id: global_storages).delete_all
        Model::Storage.where(id: global_storages).delete_all
        global_storages.clear
      end
      if f = fixture
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "preserves ordinary callers' domain-owned lists without a selector" do
      f = build.call.not_nil!
      own = Model::Generator.asset_category(f.acadian.authority).save!
      foreign = Model::Generator.asset_category(f.ucla.authority).save!
      result = domain_scope_get("#{AssetCategories.base_route}?limit=500", f.acadian.admin)
      result.status_code.should eq 200
      ids = Spec::Tenancy.ids(result.body)
      ids.should contain(own.id)
      ids.should_not contain(foreign.id)
    end

    it "lists and reads the selected customer's categories using the partner's unchanged token and Host" do
      f = build.call.not_nil!
      target = Model::Generator.asset_category(f.acadian.authority).save!
      home = Model::Generator.asset_category(f.ntt_staff.authority).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      result = domain_scope_get("#{AssetCategories.base_route}#{suffix}", f.ntt_staff.admin)
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).should contain(target.id)
      Spec::Tenancy.ids(result.body).should_not contain(home.id)
      domain_scope_get("#{AssetCategories.base_route}#{target.id}#{suffix}", f.ntt_staff.admin).status_code.should eq 200
      domain_scope_get("#{AssetCategories.base_route}#{home.id}#{suffix}", f.ntt_staff.admin).status_code.should eq 404
    end

    it "creates categories under the selected organisation's authority" do
      f = build.call.not_nil!
      result = client.post("#{AssetCategories.base_route}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {name: "Selected category #{random_name}"}.to_json)
      result.status_code.should eq 201
      JSON.parse(result.body)["authority_id"].as_s.should eq f.acadian.authority.id
    end

    it "refuses a category parent from a different selected organisation on update" do
      f = build.call.not_nil!
      home = Model::Generator.asset_category(f.ntt_staff.authority).save!
      target = Model::Generator.asset_category(f.acadian.authority).save!
      result = client.patch("#{AssetCategories.base_route}#{home.id}?organisation_id=#{f.ntt_staff.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {parent_category_id: target.id}.to_json)
      result.status_code.should eq 404
      Model::AssetCategory.find!(home.id.as(String)).parent_category_id.should be_nil
    end

    it "rechecks a changed asset type's category against the selection" do
      f = build.call.not_nil!
      home = Model::Generator.asset_category(f.ntt_staff.authority).save!
      target = Model::Generator.asset_category(f.acadian.authority).save!
      type = Model::Generator.asset_type(home).save!
      result = client.patch("#{AssetTypes.base_route}#{type.id}?organisation_id=#{f.ntt_staff.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {category_id: target.id}.to_json)
      result.status_code.should eq 404
      Model::AssetType.find!(type.id.as(String)).category_id.should eq home.id
    end

    it "lists groups in the selected domain and conceals sibling group ids" do
      f = build.call.not_nil!
      target = Model::Generator.group(authority: f.acadian.authority).save!
      home = Model::Generator.group(authority: f.ntt_staff.authority).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      result = domain_scope_get("#{Groups.base_route}#{suffix}", f.ntt_staff.admin)
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).should contain(target.id.to_s)
      Spec::Tenancy.ids(result.body).should_not contain(home.id.to_s)
      domain_scope_get("#{Groups.base_route}#{home.id}#{suffix}", f.ntt_staff.admin).status_code.should eq 404
    end

    it "reads the selected customer's signage playlist" do
      f = build.call.not_nil!
      target = Model::Generator.playlist(authority: f.acadian.authority).save!
      result = domain_scope_get("#{Playlist.base_route}/#{target.id}?organisation_id=#{f.acadian.organisation.id}", f.ntt_staff.admin)
      result.status_code.should eq 200
      JSON.parse(result.body)["id"].as_s.should eq target.id
    end

    it "scopes dashboards and alerts for partner administrators to the selection" do
      f = build.call.not_nil!
      home_dashboard = Model::Generator.alert_dashboard(authority_id: f.ntt_staff.authority.id).save!
      target_dashboard = Model::Generator.alert_dashboard(authority_id: f.acadian.authority.id).save!
      home_alert = Model::Generator.alert(alert_dashboard_id: home_dashboard.id).save!
      target_alert = Model::Generator.alert(alert_dashboard_id: target_dashboard.id).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      dashboards = domain_scope_get("#{AlertDashboards.base_route}#{suffix}", f.ntt_staff.admin)
      dashboards.status_code.should eq 200
      Spec::Tenancy.ids(dashboards.body).should contain(target_dashboard.id)
      Spec::Tenancy.ids(dashboards.body).should_not contain(home_dashboard.id)
      alerts = domain_scope_get("#{Alerts.base_route}#{suffix}", f.ntt_staff.admin)
      alerts.status_code.should eq 200
      Spec::Tenancy.ids(alerts.body).should contain(target_alert.id)
      Spec::Tenancy.ids(alerts.body).should_not contain(home_alert.id)
      domain_scope_get("#{Alerts.base_route}#{home_alert.id}#{suffix}", f.ntt_staff.admin).status_code.should eq 404
    end

    it "rechecks a changed alert dashboard reference" do
      f = build.call.not_nil!
      home = Model::Generator.alert_dashboard(authority_id: f.ntt_staff.authority.id).save!
      target = Model::Generator.alert_dashboard(authority_id: f.acadian.authority.id).save!
      alert = Model::Generator.alert(alert_dashboard_id: home.id).save!
      result = client.patch("#{Alerts.base_route}#{alert.id}?organisation_id=#{f.ntt_staff.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {alert_dashboard_id: target.id}.to_json)
      result.status_code.should eq 404
      Model::Alert.find!(alert.id.as(String)).alert_dashboard_id.should eq home.id
    end

    it "conceals storage ids from a sibling organisation" do
      f = build.call.not_nil!
      home = Model::Generator.storage(authority_id: f.ntt_staff.authority.id).save!
      result = domain_scope_get("#{Storages.base_route}/#{home.id}?organisation_id=#{f.acadian.organisation.id}", f.ntt_staff.admin)
      result.status_code.should eq 404
    end

    it "rejects moving storage ownership through a changed authority reference" do
      f = build.call.not_nil!
      home = Model::Generator.storage(authority_id: f.ntt_staff.authority.id).save!
      result = client.patch("#{Storages.base_route}/#{home.id}?organisation_id=#{f.ntt_staff.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: {authority_id: f.acadian.authority.id}.to_json)
      result.status_code.should eq 404
      Model::Storage.find!(home.id.as(String)).authority_id.should eq f.ntt_staff.authority.id
    end

    it "refuses signing another organisation's upload even for partner administrators" do
      f = build.call.not_nil!
      storage = Model::Generator.storage(authority_id: f.ntt_staff.authority.id).save!
      upload = Model::Generator.upload(f.ntt_staff.admin, storage.id).save!
      result = domain_scope_get("#{Uploads.base_route}/#{upload.id}/url?organisation_id=#{f.acadian.organisation.id}", f.ntt_staff.admin)
      result.status_code.should eq 404
    end

    it "lists uploads in the selected domain's storage" do
      f = build.call.not_nil!
      home_storage = Model::Generator.storage(authority_id: f.ntt_staff.authority.id).save!
      target_storage = Model::Generator.storage(authority_id: f.acadian.authority.id).save!
      home = Model::Generator.upload(f.ntt_staff.admin, home_storage.id).save!
      target = Model::Generator.upload(f.acadian.admin, target_storage.id).save!
      result = domain_scope_get("#{Uploads.base_route}?organisation_id=#{f.acadian.organisation.id}", f.ntt_staff.admin)
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).should contain(target.id)
      Spec::Tenancy.ids(result.body).should_not contain(home.id)
    end

    it "records immutable upload authority on shared storage and never resumes another selected organisation's upload" do
      f = build.call.not_nil!
      storage = Model::Generator.storage.save!
      global_storages << storage.id.as(String)
      payload = {file_name: "shared-#{random_name}.png", file_size: 50, file_id: "checksum", file_mime: "image/png"}.to_json
      first = client.post("#{Uploads.base_route}?organisation_id=#{f.acadian.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: payload)
      first.status_code.should eq 200
      first_id = JSON.parse(first.body)["upload_id"].as_s
      upload = Model::Upload.find!(first_id)
      upload.object_options["authority_id"]?.try(&.as_s).should eq f.acadian.authority.id
      upload.object_key.should start_with("/#{f.acadian.authority.domain}/")
      second = client.post("#{Uploads.base_route}?organisation_id=#{f.ntt_staff.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: payload)
      second.status_code.should eq 200
      JSON.parse(second.body)["upload_id"].as_s.should_not eq first_id
    end

    it "requires an explicit domain when a selected foreign organisation has several authorities" do
      f = build.call.not_nil!
      extra = Model::Generator.authority("second.acadian.test").tap(&.organisation_id = f.acadian.organisation.id).save!
      base = "#{AssetCategories.base_route}?organisation_id=#{f.acadian.organisation.id}"
      body = {name: "Ambiguous #{random_name}"}.to_json
      ambiguous = client.post(base, headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: body)
      ambiguous.status_code.should eq 400
      result = client.post("#{base}&authority_id=#{extra.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: body)
      result.status_code.should eq 201
      JSON.parse(result.body)["authority_id"].as_s.should eq extra.id
    end
  end
end
