require "../helper"

module PlaceOS::Api
  describe "organisation collections spanning domains" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    second = nil.as(Model::Authority?)
    global_storages = [] of String
    build = -> {
      fixture = f = Spec::Tenancy.build
      second = Model::Generator.authority("second.acadian.test").tap(&.organisation_id = f.acadian.organisation.id).save!
      {f, second.not_nil!}
    }

    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        authorities = [f.ntt_staff.authority.id, f.acadian.authority.id, f.ucla.authority.id, second.try(&.id)].compact
        storage_ids = Model::Storage.where(authority_id: authorities).to_a.compact_map(&.id) + global_storages
        unless storage_ids.empty?
          Model::Upload.where(storage_id: storage_ids).delete_all
          Model::Storage.where(id: storage_ids).delete_all
        end
        global_storages.clear
        Spec::Tenancy.teardown(f)
        fixture = nil
        second = nil
      end
    end

    it "lists both domains' asset collections before applying pagination" do
      f, other = build.call
      first_category = Model::Generator.asset_category(f.acadian.authority).save!
      second_category = Model::Generator.asset_category(other).save!
      first_type = Model::Generator.asset_type(first_category).save!
      second_type = Model::Generator.asset_type(second_category).save!
      first_order = Model::Generator.asset_purchase_order(f.acadian.authority).save!
      second_order = Model::Generator.asset_purchase_order(other).save!
      first_asset = Model::Asset.new(asset_type_id: first_type.id, purchase_order_id: first_order.id, zone_id: f.acadian.building.id).save!
      second_asset = Model::Asset.new(asset_type_id: second_type.id, purchase_order_id: second_order.id, zone_id: f.acadian.building.id).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      [
        {AssetCategories.base_route, first_category.id, second_category.id},
        {AssetTypes.base_route, first_type.id, second_type.id},
        {AssetPurchaseOrders.base_route, first_order.id, second_order.id},
        {Assets.base_route, first_asset.id, second_asset.id},
      ].each do |(path, first_id, second_id)|
        response = client.get("#{path}#{suffix}", headers: headers)
        response.status_code.should eq 200
        Spec::Tenancy.ids(response.body).sort.should eq [first_id.as(String), second_id.as(String)].sort
      end
      page = client.get("#{AssetCategories.base_route}#{suffix}&limit=1", headers: headers)
      page.status_code.should eq 200
      page.headers["X-Total-Count"].should eq "2"
      Spec::Tenancy.ids(page.body).size.should eq 1
    end

    it "keeps implicit home-domain results and only broadens after explicit organisation selection" do
      f, other = build.call
      first = Model::Generator.asset_category(f.acadian.authority).save!
      second_category = Model::Generator.asset_category(other).save!
      headers = Spec::Tenancy.headers(f.acadian.admin)
      home = client.get(AssetCategories.base_route, headers: headers)
      home.status_code.should eq 200
      Spec::Tenancy.ids(home.body).should eq [first.id]
      selected = client.get("#{AssetCategories.base_route}?organisation_id=#{f.acadian.organisation.id}", headers: headers)
      selected.status_code.should eq 200
      Spec::Tenancy.ids(selected.body).sort.should eq [first.id.as(String), second_category.id.as(String)].sort
    end

    it "narrows an organisation collection by an explicit authority and exact authority grant" do
      f, other = build.call
      first = Model::Generator.asset_category(f.acadian.authority).save!
      second_category = Model::Generator.asset_category(other).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      result = client.get("#{AssetCategories.base_route}#{suffix}&authority_id=#{other.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin))
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).should eq [second_category.id]
      client.get("#{AssetCategories.base_route}#{suffix}&authority_id=#{f.ntt_staff.authority.id}", headers: Spec::Tenancy.headers(f.ntt_staff.admin)).status_code.should eq 404
      Model::Generator.grant(f.ucla.admin, "authority", other.id.as(String), Model::Permissions::Read).save!
      granted = client.get("#{AssetCategories.base_route}#{suffix}", headers: Spec::Tenancy.headers(f.ucla.admin))
      granted.status_code.should eq 200
      Spec::Tenancy.ids(granted.body).should eq [second_category.id]
      Spec::Tenancy.ids(granted.body).should_not contain(first.id)
    end

    it "lists groups and signage from every selected domain with scoped counts" do
      f, other = build.call
      first_group = Model::Generator.group(authority: f.acadian.authority).save!
      second_group = Model::Generator.group(authority: other).save!
      first_playlist = Model::Generator.playlist(authority: f.acadian.authority).save!
      second_playlist = Model::Generator.playlist(authority: other).save!
      first_item = Model::Generator.item(authority: f.acadian.authority).save!
      second_item = Model::Generator.item(authority: other).save!
      first_template = Model::Generator.signage_template(authority: f.acadian.authority).save!
      second_template = Model::Generator.signage_template(authority: other).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      [
        {Groups.base_route, first_group.id.to_s, second_group.id.to_s},
        {Playlist.base_route, first_playlist.id.as(String), second_playlist.id.as(String)},
        {PlaylistMedia.base_route, first_item.id.as(String), second_item.id.as(String)},
        {SignageTemplates.base_route, first_template.id.to_s, second_template.id.to_s},
      ].each do |(path, first_id, second_id)|
        result = client.get("#{path}#{suffix}", headers: headers)
        result.status_code.should eq 200
        Spec::Tenancy.ids(result.body).sort.should eq [first_id, second_id].sort
        result.headers["X-Total-Count"].should eq "2"
      end
    end

    it "expands selected customer signage groups inside the addressed domain" do
      f, other = build.call
      root = Model::Generator.group(authority: f.acadian.authority).save!
      child = Model::Generator.group(authority: f.acadian.authority, parent: root).save!
      sibling = Model::Generator.group(authority: other).save!
      direct = Model::Generator.playlist(authority: f.acadian.authority).save!
      nested = Model::Generator.playlist(authority: f.acadian.authority).save!
      sibling_playlist = Model::Generator.playlist(authority: other).save!
      Model::Generator.group_playlist(group: root, playlist: direct).save!
      Model::Generator.group_playlist(group: child, playlist: nested).save!
      Model::Generator.group_playlist(group: sibling, playlist: sibling_playlist).save!
      root_item = Model::Generator.item(authority: f.acadian.authority).tap(&.tags = Set{"direct"}).save!
      child_item = Model::Generator.item(authority: f.acadian.authority).tap(&.tags = Set{"nested"}).save!
      sibling_item = Model::Generator.item(authority: other).tap(&.tags = Set{"sibling"}).save!
      Model::Generator.group_playlist_item(group: root, playlist_item: root_item).save!
      Model::Generator.group_playlist_item(group: child, playlist_item: child_item).save!
      Model::Generator.group_playlist_item(group: sibling, playlist_item: sibling_item).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}&group_id=#{root.id}"
      initial = client.get("#{Playlist.base_route}#{suffix}", headers: headers)
      initial.status_code.should eq 200
      Spec::Tenancy.ids(initial.body).should eq [direct.id]
      suffix += "&include_child_data=true"
      [
        {Playlist.base_route, direct.id.as(String), nested.id.as(String)},
        {PlaylistMedia.base_route, root_item.id.as(String), child_item.id.as(String)},
      ].each do |(route, first_id, second_id)|
        expanded = client.get("#{route}#{suffix}", headers: headers)
        expanded.status_code.should eq 200
        Spec::Tenancy.ids(expanded.body).sort.should eq [first_id, second_id].sort
        expanded.headers["X-Total-Count"].should eq "2"
      end
      tags = client.get("#{PlaylistMedia.base_route}/tags#{suffix}", headers: headers)
      tags.status_code.should eq 200
      Array(String).from_json(tags.body).sort.should eq ["direct", "nested"]
      counts = client.get("#{PlaylistMedia.base_route}/tag_counts#{suffix}", headers: headers)
      counts.status_code.should eq 200
      Hash(String, Int32).from_json(counts.body).should eq({"direct" => 1, "nested" => 1})
    end

    it "accepts either storage authority selector and rejects conflicting or repeated selectors" do
      f, other = build.call
      Model::Generator.storage(authority_id: f.acadian.authority.id).save!
      selected = Model::Generator.storage(authority_id: other.id).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      ["authority_id", "auth_id"].each do |parameter|
        response = client.get("#{Storages.base_route}#{suffix}&#{parameter}=#{other.id}", headers: headers)
        response.status_code.should eq 200
        Spec::Tenancy.ids(response.body).should eq [selected.id]
      end
      client.get("#{Storages.base_route}#{suffix}&authority_id=#{other.id}&auth_id=#{f.acadian.authority.id}", headers: headers).status_code.should eq 400
      client.get("#{Storages.base_route}#{suffix}&authority_id=#{other.id}&authority_id=#{other.id}", headers: headers).status_code.should eq 400
      client.get("#{Storages.base_route}#{suffix}&auth_id=#{other.id}&auth_id=#{other.id}", headers: headers).status_code.should eq 400
    end

    it "aggregates media tags across selected domains without sibling organisation tags" do
      f, other = build.call
      Model::Generator.item(authority: f.acadian.authority).tap(&.tags = Set{"common", "first-domain"}).save!
      Model::Generator.item(authority: other).tap(&.tags = Set{"common", "second-domain"}).save!
      Model::Generator.item(authority: f.ucla.authority).tap(&.tags = Set{"foreign"}).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      tags = client.get("#{PlaylistMedia.base_route}/tags#{suffix}", headers: headers)
      tags.status_code.should eq 200
      Array(String).from_json(tags.body).sort.should eq ["common", "first-domain", "second-domain"].sort
      counts = client.get("#{PlaylistMedia.base_route}/tag_counts#{suffix}", headers: headers)
      counts.status_code.should eq 200
      JSON.parse(counts.body)["common"].as_i.should eq 2
      JSON.parse(counts.body)["foreign"]?.should be_nil
    end

    it "lists uploads and counts across authority-specific default storage" do
      f, other = build.call
      first_storage = Model::Generator.storage(authority_id: f.acadian.authority.id).save!
      second_storage = Model::Generator.storage(authority_id: other.id).save!
      first = Model::Generator.upload(f.acadian.admin, first_storage.id).save!
      second_upload = Model::Generator.upload(f.acadian.admin, second_storage.id).save!
      suffix = "?organisation_id=#{f.acadian.organisation.id}&limit=1"
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      first_page = client.get("#{Uploads.base_route}#{suffix}", headers: headers)
      first_page.status_code.should eq 200
      first_page.headers["X-Total-Count"].should eq "2"
      second_page = client.get("#{Uploads.base_route}#{suffix}&offset=1", headers: headers)
      second_page.status_code.should eq 200
      (Spec::Tenancy.ids(first_page.body) + Spec::Tenancy.ids(second_page.body)).sort.should eq [first.id.as(String), second_upload.id.as(String)].sort
    end

    it "scopes shared-storage uploads by their recorded target authority across selected domains" do
      f, other = build.call
      storage = Model::Generator.storage.save!
      global_storages << storage.id.as(String)
      first = Model::Generator.upload(f.acadian.admin, storage.id).tap { |row| row.object_options["authority_id"] = JSON::Any.new(f.acadian.authority.id.as(String)) }.save!
      second_upload = Model::Generator.upload(f.acadian.admin, storage.id).tap { |row| row.object_options["authority_id"] = JSON::Any.new(other.id.as(String)) }.save!
      foreign = Model::Generator.upload(f.ucla.admin, storage.id).tap { |row| row.object_options["authority_id"] = JSON::Any.new(f.ucla.authority.id.as(String)) }.save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      result = client.get("#{Uploads.base_route}?organisation_id=#{f.acadian.organisation.id}&storage_id=#{storage.id}", headers: headers)
      result.status_code.should eq 200
      Spec::Tenancy.ids(result.body).sort.should eq [first.id.as(String), second_upload.id.as(String)].sort
      Spec::Tenancy.ids(result.body).should_not contain(foreign.id)
      own = client.get("#{Uploads.base_route}?storage_id=#{storage.id}", headers: Spec::Tenancy.headers(f.acadian.admin))
      own.status_code.should eq 200
      Spec::Tenancy.ids(own.body).should eq [first.id]
    end

    it "lists alert, storage, provider and mail collections from every selected domain" do
      f, other = build.call
      first_dashboard = Model::Generator.alert_dashboard(authority_id: f.acadian.authority.id).save!
      second_dashboard = Model::Generator.alert_dashboard(authority_id: other.id).save!
      first_alert = Model::Generator.alert(alert_dashboard_id: first_dashboard.id).save!
      second_alert = Model::Generator.alert(alert_dashboard_id: second_dashboard.id).save!
      first_storage = Model::Generator.storage(authority_id: f.acadian.authority.id).save!
      second_storage = Model::Generator.storage(authority_id: other.id).save!
      first_provider = Model::Generator.signage_ai_provider(authority: f.acadian.authority, name: "first-#{random_name}").save!
      second_provider = Model::Generator.signage_ai_provider(authority: other, name: "second-#{random_name}").save!
      first_mail = Model::Generator.pending_mail(authority: f.acadian.authority, user: f.acadian.admin).save!
      second_mail = Model::Generator.pending_mail(authority: other, user: f.acadian.admin).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      [
        {AlertDashboards.base_route, first_dashboard.id.to_s, second_dashboard.id.to_s},
        {Alerts.base_route, first_alert.id.to_s, second_alert.id.to_s},
        {Storages.base_route, first_storage.id.to_s, second_storage.id.to_s},
        {SignageAIProviders.base_route, first_provider.id.to_s, second_provider.id.to_s},
        {PendingMails.base_route, first_mail.id.to_s, second_mail.id.to_s},
      ].each do |(path, first_id, second_id)|
        result = client.get("#{path}#{suffix}", headers: headers)
        result.status_code.should eq 200
        Spec::Tenancy.ids(result.body).should contain(first_id)
        Spec::Tenancy.ids(result.body).should contain(second_id)
      end
    end

    it "lists AI jobs across selected domains and infers each direct job's authority" do
      f, other = build.call
      first = Model::Generator.signage_ai_job(authority: f.acadian.authority, user: f.ntt_staff.admin, state: Model::SignageAIJob::State::Done).save!
      second_job = Model::Generator.signage_ai_job(authority: other, user: f.ntt_staff.admin, state: Model::SignageAIJob::State::Done).save!
      map_job = Model::Generator.signage_ai_job(authority: other, user: f.ntt_staff.admin, kind: Model::SignageAIJob::Kind::MapEdit, state: Model::SignageAIJob::State::Done).save!
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      suffix = "?organisation_id=#{f.acadian.organisation.id}"
      jobs = client.get("#{SignageAI.base_route}/jobs#{suffix}", headers: headers)
      jobs.status_code.should eq 200
      Spec::Tenancy.ids(jobs.body).sort.should eq [first.id.to_s, second_job.id.to_s].sort
      client.get("#{SignageAI.base_route}/jobs/#{second_job.id}#{suffix}", headers: headers).status_code.should eq 200
      maps = client.get("#{MapAI.base_route}/jobs#{suffix}", headers: headers)
      maps.status_code.should eq 200
      Spec::Tenancy.ids(maps.body).should eq [map_job.id.to_s]
      client.get("#{MapAI.base_route}/jobs/#{map_job.id}#{suffix}", headers: headers).status_code.should eq 200
    end
  end
end
