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
        authorities = [f.ntt_staff.authority.id, f.acadian.authority.id, f.ucla.authority.id].compact
        storage_ids = Model::Storage.where(authority_id: authorities).to_a.compact_map(&.id)
        unless storage_ids.empty?
          Model::Upload.where(storage_id: storage_ids).delete_all
          Model::Storage.where(id: storage_ids).delete_all
        end
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

    it "rolls back a bulk asset create when a later asset refers to another organisation" do
      f = build.call.not_nil!
      own_category = Model::Generator.asset_category(f.ntt_staff.authority).save!
      own_type = Model::Generator.asset_type(own_category).save!
      foreign_category = Model::Generator.asset_category(f.acadian.authority).save!
      foreign_type = Model::Generator.asset_type(foreign_category).save!
      order = Model::Generator.asset_purchase_order(f.ntt_staff.authority).save!
      first = Model::Asset.new(asset_type_id: own_type.id, purchase_order_id: order.id, zone_id: f.ntt_staff.building.id)
      second = Model::Asset.new(asset_type_id: foreign_type.id, purchase_order_id: order.id, zone_id: f.acadian.building.id)
      result = client.post("#{Assets.base_route}bulk?organisation_id=#{f.ntt_staff.organisation.id}",
        headers: Spec::Tenancy.headers(f.ntt_staff.admin), body: [first, second].to_json)
      result.status_code.should eq 404
      Model::Asset.where(asset_type_id: own_type.id).count.should eq 0
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

    it "preserves a name-only group PATCH without an authority field" do
      f = build.call.not_nil!
      group = Model::Generator.group(authority: f.acadian.authority).save!
      result = client.patch("#{Groups.base_route}#{group.id}", headers: Spec::Tenancy.headers(f.acadian.admin), body: {name: "Renamed without authority"}.to_json)
      result.status_code.should eq 200
      updated = Model::Group.find!(group.id.as(UUID))
      updated.name.should eq "Renamed without authority"
      updated.authority_id.should eq f.acadian.authority.id
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

    it "does not let a read-only upload OAuth scope sign a new upload" do
      f = build.call.not_nil!
      headers = Spec::Tenancy.headers(f.acadian.admin)
      token = Model::UserJWT.decode(headers["Authorization"].split(' ').last)
      scopes = [Model::UserJWT::Scope.new("uploads", Model::UserJWT::Scope::Access::Read)]
      headers["Authorization"] = "Bearer #{Model::UserJWT.new(iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, user: token.user, scope: scopes).encode}"
      result = client.post(Uploads.base_route, headers: headers,
        body: {file_name: "read-only.png", file_size: 50, file_id: "checksum", file_mime: "image/png"}.to_json)
      result.status_code.should eq 403
    end

    it "does not send a brand-logo upload from another organisation to the image vendor" do
      f = build.call.not_nil!
      storage = Model::Generator.storage(authority_id: f.acadian.authority.id).save!
      foreign_storage = Model::Generator.storage(authority_id: f.ucla.authority.id).save!
      Model::Generator.signage_ai_provider(authority: f.acadian.authority, name: "selected-#{random_name}", is_default: true).save!
      source = Model::Generator.upload(f.ntt_staff.admin, storage.id, file_name: "source.png").save!
      logo = Model::Generator.upload(f.ucla.admin, foreign_storage.id, file_name: "foreign-logo.png").save!
      Model::Metadata.new(parent_id: f.acadian.org_zone.id, name: "signage_ai", details: JSON.parse({logo_upload_id: logo.id}.to_json)).save!
      HttpMocks.signage_ai_vendor
      HttpMocks.signage_ai_storage
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      result = client.post("#{SignageAI.base_route}/edit?organisation_id=#{f.acadian.organisation.id}", headers: headers,
        body: {prompt: "make it warmer", candidates: 1, include_logo: true, source_upload_id: source.id}.to_json)
      result.status_code.should eq 202
      job_id = UUID.new(JSON.parse(result.body)["id"].as_s)
      job = Model::SignageAIJob.find!(job_id)
      100.times do
        break if job.final?
        sleep 100.milliseconds
        job = Model::SignageAIJob.find!(job_id)
      end
      job.final?.should be_true
      job.upload_ids.should_not contain(logo.id)
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
