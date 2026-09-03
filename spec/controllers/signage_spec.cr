require "../helper"
require "timecop"

module PlaceOS::Api
  describe Signage do
    ::Spec.before_each do
      Model::SignageTemplate::SystemTemplate.clear
      Model::SignageTemplate.clear
      Model::Playlist::ItemSchedule.clear
      Model::Playlist::Revision.clear
      Model::Playlist::Item.clear
      Model::Playlist.clear
      Model::TriggerInstance.clear
      Model::ControlSystem.clear
    end

    describe "/api/engine/v2/signage" do
      it "GET /api/engine/v2/signage/:system_id" do
        revision = Model::Generator.revision

        item = Model::Generator.item
        item.save!
        item1_id = item.id.as(String)
        item2 = Model::Generator.item
        item2.save!
        item2_id = item2.id.as(String)

        revision.items = [item1_id, item2_id]
        revision.approved = true
        revision.save!
        playlist = revision.playlist.as(Model::Playlist)
        playlist_id = playlist.id.as(String)

        system = Model::Generator.control_system
        system.signage = true
        system.playlists = [playlist_id]
        system.save!
        system_id = system.id.as(String)

        headers = Spec::Authentication.headers

        result = client.get(
          path: "#{Signage.base_route}/#{system_id}",
          headers: headers,
        )

        json = JSON.parse result.body
        json["playlist_mappings"].should eq({system_id => [playlist_id]})
        json["playlist_config"][playlist_id][0]["id"].should eq playlist_id
        json["playlist_config"][playlist_id][1].should eq [item1_id, item2_id]
        json["playlist_media"][0]["id"].should eq item1_id
        json["playlist_media"][1]["id"].should eq item2_id

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        result = client.get(
          path: "#{Signage.base_route}/#{system_id}",
          headers: headers,
        )

        result.body.should eq ""
        result.status_code.should eq 304
      end

      it "expands a distribution playlist into per-item virtual playlists" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        playlist = Model::Generator.playlist(authority: authority, distribution: true).save!
        playlist_id = playlist.id.as(String)

        item_a = Model::Generator.item(authority: authority).save!
        item_b = Model::Generator.item(authority: authority).save!

        # each scheduled item carries its own schedule
        schedule_a = Model::Generator.item_schedule(
          playlist: playlist, item: item_a,
          schedules: [Model::Playlist::Schedule.new(play_cron: "0 9 * * *")],
        ).save!
        schedule_b = Model::Generator.item_schedule(
          playlist: playlist, item: item_b,
          schedules: [Model::Playlist::Schedule.new(play_cron: "0 17 * * *")],
        ).save!
        schedule_a_id = schedule_a.id.as(String)
        schedule_b_id = schedule_b.id.as(String)

        revision = Model::Generator.revision(playlist: playlist)
        revision.items = [schedule_a_id, schedule_b_id]
        revision.approved = true
        revision.save!

        system = Model::Generator.control_system
        system.signage = true
        system.playlists = [playlist_id]
        system.save!
        system_id = system.id.as(String)

        result = client.get(
          path: "#{Signage.base_route}/#{system_id}",
          headers: Spec::Authentication.headers,
        )

        json = JSON.parse result.body

        # the distribution playlist id is replaced by its virtual (schedule) ids
        json["playlist_mappings"].should eq({system_id => [schedule_a_id, schedule_b_id]})

        config = json["playlist_config"].as_h
        config.keys.sort!.should eq [schedule_a_id, schedule_b_id].sort
        config.has_key?(playlist_id).should be_false

        # each virtual playlist is keyed by the schedule id, holds a single media
        # item, and carries that schedule's own schedules
        json["playlist_config"][schedule_a_id][0]["id"].should eq schedule_a_id
        json["playlist_config"][schedule_a_id][0]["distribution"].should eq false
        json["playlist_config"][schedule_a_id][0]["schedules"][0]["play_cron"].should eq "0 9 * * *"
        json["playlist_config"][schedule_a_id][1].should eq [item_a.id.as(String)]

        json["playlist_config"][schedule_b_id][0]["id"].should eq schedule_b_id
        json["playlist_config"][schedule_b_id][0]["schedules"][0]["play_cron"].should eq "0 17 * * *"
        json["playlist_config"][schedule_b_id][1].should eq [item_b.id.as(String)]

        # the underlying media items are still cached in playlist_media
        media_ids = json["playlist_media"].as_a.map(&.["id"].as_s).sort!
        media_ids.should eq [item_a.id.as(String), item_b.id.as(String)].sort
      end

      it "includes applied signage templates in the display response" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        background = Model::Generator.item(authority: authority).save!
        widget = Model::Generator.widget_plugin(authority: authority).save!

        layout = Model::SignageTemplate::Layout.new(
          position: Model::SignageTemplate::Layout::Position::Top,
          plugin_id: widget.id.as(String),
          y_pos: 0.2_f32,
        )

        template = Model::Generator.signage_template(authority: authority, layouts: [layout])
        template.background_item_id = background.id
        template.approved = true
        template.save!

        zone_template = Model::Generator.signage_template(authority: authority)
        zone_template.approved = true
        zone_template.save!

        # never approved, so never shown on displays
        pending_template = Model::Generator.signage_template(authority: authority).save!

        zone = Model::Generator.zone.save!
        system = Model::Generator.control_system
        system.signage = true
        system.zones = [zone.id.as(String)]
        system.save!
        system_id = system.id.as(String)

        direct = Model::Generator.system_template(template: template, control_system: system).save!
        zoned = Model::Generator.system_template(
          template: zone_template, zone: zone,
          schedule: Model::Playlist::Schedule.new(play_cron: "0 9 * * *"),
        ).save!
        Model::Generator.system_template(template: pending_template, control_system: system).save!

        result = client.get(
          path: "#{Signage.base_route}/#{system_id}",
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200
        json = JSON.parse result.body

        schedules = json["template_schedules"].as_a
        schedules.map(&.["id"].as_s).sort!.should eq [direct.id.to_s, zoned.id.to_s].sort

        hydrated = schedules.find! { |mapping| mapping["id"].as_s == direct.id.to_s }
        hydrated["template_details"]["id"].as_s.should eq template.id.to_s
        hydrated["template_details"]["background_media"]["id"].as_s.should eq background.id.as(String)

        from_zone = schedules.find! { |mapping| mapping["id"].as_s == zoned.id.to_s }
        from_zone["template_details"]["id"].as_s.should eq zone_template.id.to_s
        from_zone["schedule"]["play_cron"].as_s.should eq "0 9 * * *"

        # widget plugins referenced by template layouts are included
        json["signage_plugins"].as_a.map(&.["id"].as_s).should contain(widget.id.as(String))
      end

      it "returns a single default template, preferring the most specific mapping" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        org_zone = Model::Generator.zone.save!
        older_zone = Model::Generator.zone
        older_zone.parent_id = org_zone.id
        older_zone.save!
        newer_zone = Model::Generator.zone
        newer_zone.parent_id = org_zone.id
        newer_zone.save!

        system = Model::Generator.control_system
        system.signage = true
        system.zones = [org_zone.id.as(String), older_zone.id.as(String), newer_zone.id.as(String)]
        system.save!
        system_id = system.id.as(String)

        templates = Array.new(5) do
          template = Model::Generator.signage_template(authority: authority)
          template.approved = true
          template.save!
        end

        Model::Generator.system_template(template: templates[0], zone: org_zone).save!
        older_default = Model::Generator.system_template(template: templates[1], zone: older_zone).save!
        Model::Generator.system_template(template: templates[2], zone: newer_zone).save!
        # scheduled mappings are never filtered
        scheduled = Model::Generator.system_template(
          template: templates[3], zone: org_zone,
          schedule: Model::Playlist::Schedule.new(play_cron: "0 9 * * *"),
        ).save!

        get_ids = -> do
          result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          JSON.parse(result.body)["template_schedules"].as_a.map(&.["id"].as_s).sort!
        end

        # the deepest zone wins, ties broken by the older zone
        get_ids.call.should eq [older_default.id.to_s, scheduled.id.to_s].sort

        # a mapping directly on the system outranks every zone default
        direct_default = Model::Generator.system_template(template: templates[4], control_system: system).save!
        get_ids.call.should eq [direct_default.id.to_s, scheduled.id.to_s].sort
      end

      it "invalidates cached signage when templates or their schedules change" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        template = Model::Generator.signage_template(authority: authority)
        template.approved = true
        template.save!

        # not yet approved, its mapping is hidden
        pending_template = Model::Generator.signage_template(authority: authority).save!

        system = Model::Generator.control_system
        system.signage = true
        system.save!
        system_id = system.id.as(String)

        mapping = Model::Generator.system_template(template: template, control_system: system).save!
        Model::Generator.system_template(
          template: pending_template, control_system: system,
          schedule: Model::Playlist::Schedule.new(play_cron: "30 8 * * *"),
        ).save!

        headers = Spec::Authentication.headers
        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        json = JSON.parse result.body
        json["template_schedules"].as_a.map(&.["id"].as_s).should eq [mapping.id.to_s]

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers).status_code.should eq 304

        # skip forward a moment (Last-Modified has second granularity)
        sleep 1.seconds

        # updating a mapping schedule moves Last-Modified forward
        mapping.schedule = Model::Playlist::Schedule.new(play_cron: "0 17 * * *")
        mapping.save!

        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers).status_code.should eq 304

        sleep 1.seconds

        # approving a template moves Last-Modified forward and reveals its mappings
        pending_template.approved = true
        pending_template.save!

        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["template_schedules"].as_a.size.should eq 2
      end

      it "invalidates cached signage when media items are edited or removed" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        # item rendered via a playlist mapped to the display
        playlist_item = Model::Generator.item(authority: authority).save!
        playlist_item_id = playlist_item.id.as(String)

        revision = Model::Generator.revision
        revision.items = [playlist_item_id]
        revision.approved = true
        revision.save!
        playlist = revision.playlist.as(Model::Playlist)

        # item referenced only as an approved template background
        background_item = Model::Generator.item(authority: authority).save!
        template = Model::Generator.signage_template(authority: authority)
        template.background_item_id = background_item.id
        template.approved = true
        template.save!

        system = Model::Generator.control_system
        system.signage = true
        system.playlists = [playlist.id.as(String)]
        system.save!
        system_id = system.id.as(String)

        Model::Generator.system_template(template: template, control_system: system).save!

        headers = Spec::Authentication.headers
        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        last_modified = Time::Format::HTTP_DATE.parse(result.headers["Last-Modified"])

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers).status_code.should eq 304

        # skip forward a moment (Last-Modified has second granularity)
        sleep 1.seconds

        # editing playlist media busts the cache (the playlist is touched)
        client.patch(
          path: "#{PlaylistMedia.base_route}/#{playlist_item_id}",
          headers: Spec::Authentication.headers,
          body: {name: "updated media name"}.to_json,
        ).status_code.should eq 200

        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        updated = Time::Format::HTTP_DATE.parse(result.headers["Last-Modified"])
        updated.should be > last_modified
        last_modified = updated

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers).status_code.should eq 304

        sleep 1.seconds

        # editing a template's background media busts the cache (the template is touched)
        client.patch(
          path: "#{PlaylistMedia.base_route}/#{background_item.id}",
          headers: Spec::Authentication.headers,
          body: {name: "updated background name"}.to_json,
        ).status_code.should eq 200

        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        updated = Time::Format::HTTP_DATE.parse(result.headers["Last-Modified"])
        updated.should be > last_modified
        last_modified = updated

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers).status_code.should eq 304

        sleep 1.seconds

        # deleting media busts the cache and removes the item from the payload
        client.delete(
          path: "#{PlaylistMedia.base_route}/#{playlist_item_id}",
          headers: Spec::Authentication.headers,
        ).status_code.should eq 202

        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        Time::Format::HTTP_DATE.parse(result.headers["Last-Modified"]).should be > last_modified
        JSON.parse(result.body)["playlist_media"].as_a.map(&.["id"].as_s).should_not contain playlist_item_id
      end

      it "busts the cache when a zone's playlists change" do
        revision = Model::Generator.revision
        item = Model::Generator.item.save!
        revision.items = [item.id.as(String)]
        revision.approved = true
        revision.save!
        playlist_id = revision.playlist_id.as(String)

        zone = Model::Generator.zone
        zone.playlists = [playlist_id]
        zone.save!
        zone_id = zone.id.as(String)

        system = Model::Generator.control_system
        system.signage = true
        system.zones = [zone_id]
        system.save!
        system_id = system.id.as(String)

        headers = Spec::Authentication.headers
        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["playlist_mappings"].should eq({system_id => [] of String, zone_id => [playlist_id]})
        last_modified = Time::Format::HTTP_DATE.parse(result.headers["Last-Modified"])

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers).status_code.should eq 304

        # skip forward a moment (Last-Modified has second granularity)
        sleep 1.seconds

        # removing the playlist from the zone only moves the zone row
        zone.playlists = [] of String
        zone.save!

        result = client.get(path: "#{Signage.base_route}/#{system_id}", headers: headers)
        result.status_code.should eq 200
        Time::Format::HTTP_DATE.parse(result.headers["Last-Modified"]).should be > last_modified
        JSON.parse(result.body)["playlist_mappings"].should eq({system_id => [] of String})
      end

      it "busts the ETag on removals, plugin edits and back-to-back changes" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        revision = Model::Generator.revision
        item = Model::Generator.item(authority: authority).save!
        revision.items = [item.id.as(String)]
        revision.approved = true
        revision.save!
        playlist = revision.playlist.as(Model::Playlist)
        playlist_id = playlist.id.as(String)

        trigger_playlist = Model::Generator.playlist(authority: authority).save!
        trigger_playlist_id = trigger_playlist.id.as(String)

        widget = Model::Generator.widget_plugin(authority: authority).save!
        layout = Model::SignageTemplate::Layout.new(
          position: Model::SignageTemplate::Layout::Position::Top,
          plugin_id: widget.id.as(String),
          y_pos: 0.2_f32,
        )
        template = Model::Generator.signage_template(authority: authority, layouts: [layout])
        template.approved = true
        template.save!

        system = Model::Generator.control_system
        system.signage = true
        system.playlists = [playlist_id]
        system.save!
        system_id = system.id.as(String)

        mapping = Model::Generator.system_template(template: template, control_system: system).save!

        trigger_instance = Model::Generator.trigger_instance(control_system: system)
        trigger_instance.playlists = [trigger_playlist_id]
        trigger_instance.save!
        trigger_instance_id = trigger_instance.id.as(String)

        path = "#{Signage.base_route}/#{system_id}"
        headers = Spec::Authentication.headers

        # fetch the current payload, then assert a conditional request is a 304
        # (nothing changed) and returns the payload again after `change` runs
        expect_bust = ->(change : Proc(Nil)) : JSON::Any {
          result = client.get(path: path, headers: headers)
          result.status_code.should eq 200
          etag = result.headers["ETag"]
          etag.should start_with %(")

          cached = headers.dup
          cached["If-None-Match"] = etag
          client.get(path: path, headers: cached).status_code.should eq 304

          change.call

          result = client.get(path: path, headers: cached)
          result.status_code.should eq 200
          result.headers["ETag"].should_not eq etag
          JSON.parse(result.body)
        }

        # no sleeps: changes land inside the same second as the previous
        # fetch, which Last-Modified alone cannot distinguish

        # clearing a trigger instance's playlists
        json = expect_bust.call(-> {
          trigger_instance.playlists = [] of String
          trigger_instance.save!
        })
        json["playlist_mappings"].as_h.keys.should_not contain trigger_instance_id

        # re-assigning them, then deleting the trigger instance
        expect_bust.call(-> {
          trigger_instance.playlists = [trigger_playlist_id]
          trigger_instance.save!
        })["playlist_mappings"][trigger_instance_id].should eq [trigger_playlist_id]
        json = expect_bust.call(-> { trigger_instance.destroy })
        json["playlist_mappings"].as_h.keys.should_not contain trigger_instance_id

        # editing a plugin used by a template widget
        json = expect_bust.call(-> {
          widget.uri = "https://example.com/widget-v2.js"
          widget.save!
        })
        json["signage_plugins"].as_a.find! { |plugin| plugin["id"].as_s == widget.id.as(String) }["uri"].as_s.should eq "https://example.com/widget-v2.js"

        # removing the template mapping
        json = expect_bust.call(-> { mapping.destroy })
        json["template_schedules"].as_a.should be_empty

        # deleting a playlist that is still assigned to the display
        json = expect_bust.call(-> { playlist.destroy })
        json["playlist_config"].as_h.keys.should_not contain playlist_id
      end

      it "POST /api/engine/v2/signage/:system_id/metrics" do
        revision = Model::Generator.revision

        item = Model::Generator.item
        item.save!
        item1_id = item.id.as(String)
        item2 = Model::Generator.item
        item2.save!
        item2_id = item2.id.as(String)

        revision.items = [item1_id, item2_id]
        revision.approved = true
        revision.save!
        playlist = revision.playlist.as(Model::Playlist)
        playlist_id = playlist.id.as(String)

        system = Model::Generator.control_system
        system.signage = true
        system.playlists = [playlist_id]
        system.save!
        system_id = system.id.as(String)

        result = client.post(
          path: "#{Signage.base_route}/#{system_id}/metrics",
          headers: Spec::Authentication.headers,
          body: {
            play_through_counts: {
              playlist_id => 3,
            },
            playlist_counts: {
              playlist_id => 8,
            },
            media_counts: {
              item1_id => 5,
              item2_id => 2,
            },
          }.to_json,
        )

        result.status_code.should eq 202

        playlist.reload!
        playlist.play_count.should eq 8
        playlist.play_through_count.should eq 3

        item.reload!
        item.play_count.should eq 5

        item2.reload!
        item2.play_count.should eq 2
      end

      it "can approve digital signage playlists" do
        revision = Model::Generator.revision

        item = Model::Generator.item
        item.save!
        item1_id = item.id.as(String)
        item2 = Model::Generator.item
        item2.save!
        item2_id = item2.id.as(String)

        revision.items = [item1_id, item2_id]
        revision.save!
        revision.approved.should be_false
        playlist = revision.playlist.as(Model::Playlist)
        playlist_id = playlist.id.as(String)

        system = Model::Generator.control_system
        system.signage = true
        system.playlists = [playlist_id]
        system.save!
        system_id = system.id.as(String)

        headers = Spec::Authentication.headers

        result = client.get(
          path: "#{Signage.base_route}/#{system_id}",
          headers: headers,
        )

        json = JSON.parse result.body
        json["playlist_mappings"].should eq({system_id => [playlist_id]})
        json["playlist_config"][playlist_id][0]["id"].should eq playlist_id
        json["playlist_config"][playlist_id][1].should eq [] of String

        # skip forward a moment to avoid a 304
        sleep 1.seconds

        # we should now approve the playlist
        approved = client.post(
          path: "#{Signage.base_route}/playlists/#{playlist_id}/media/approve",
          headers: Spec::Authentication.headers,
        )
        approved.status_code.should eq 200

        # revision timestamp should have changed
        updated_at = revision.updated_at
        revision.reload!
        revision.approved.should be_true
        revision.updated_at.should_not eq updated_at

        system.playlists_last_updated.should eq revision.updated_at

        # the route should have modified
        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        result = client.get(
          path: "#{Signage.base_route}/#{system_id}",
          headers: headers,
        )
        result.status_code.should_not eq 304

        json = JSON.parse result.body
        json["playlist_mappings"].should eq({system_id => [playlist_id]})
        json["playlist_config"][playlist_id][0]["id"].should eq playlist_id
        json["playlist_config"][playlist_id][1].should eq [item1_id, item2_id]
        json["playlist_media"][0]["id"].should eq item1_id
        json["playlist_media"][1]["id"].should eq item2_id
      end
    end

    describe "last seen tracking" do
      it "does not record a last seen time for preview players (default)" do
        system = Model::Generator.control_system
        system.signage = true
        system.save!
        system_id = system.id.as(String)
        # reload so the comparison uses the database (microsecond) precision
        system.reload!
        initial_time = system.signage_last_seen

        client.get(path: "#{Signage.base_route}/#{system_id}", headers: Spec::Authentication.headers).status_code.should eq 200

        system.reload!
        system.signage_last_seen.should eq initial_time
        system.playlist_item_id.should be_nil
      end

      it "records the last seen time for production players without a current item" do
        system = Model::Generator.control_system
        system.signage = true
        system.save!
        system_id = system.id.as(String)
        initial_time = system.signage_last_seen

        client.get(path: "#{Signage.base_route}/#{system_id}?preview=false", headers: Spec::Authentication.headers).status_code.should eq 200

        system.reload!
        system.signage_last_seen.should_not eq initial_time
        (Time.utc - system.signage_last_seen).should be < 30.seconds
        system.playlist_item_id.should be_nil
      end

      it "records the last seen time and the currently playing item" do
        item = Model::Generator.item
        item.save!
        item_id = item.id.as(String)

        system = Model::Generator.control_system
        system.signage = true
        system.save!
        system_id = system.id.as(String)
        initial_time = system.signage_last_seen

        client.get(path: "#{Signage.base_route}/#{system_id}?preview=false&item_id=#{item_id}", headers: Spec::Authentication.headers).status_code.should eq 200

        system.reload!
        system.signage_last_seen.should_not eq initial_time
        system.playlist_item_id.should eq item_id

        # an unknown item clears the currently playing item but still updates last seen
        seen = system.signage_last_seen
        client.get(path: "#{Signage.base_route}/#{system_id}?preview=false&item_id=playlist_items-missing", headers: Spec::Authentication.headers).status_code.should eq 200
        system.reload!
        system.playlist_item_id.should be_nil
        system.signage_last_seen.should be >= seen

        # an empty item id is treated as no item
        client.get(path: "#{Signage.base_route}/#{system_id}?preview=false&item_id=#{item_id}", headers: Spec::Authentication.headers).status_code.should eq 200
        client.get(path: "#{Signage.base_route}/#{system_id}?preview=false&item_id=", headers: Spec::Authentication.headers).status_code.should eq 200
        system.reload!
        system.playlist_item_id.should be_nil
      end

      it "records the last seen time even when the client content is up to date (304)" do
        system = Model::Generator.control_system
        system.signage = true
        system.save!
        system_id = system.id.as(String)

        headers = Spec::Authentication.headers
        result = client.get(path: "#{Signage.base_route}/#{system_id}?preview=false", headers: headers)
        result.status_code.should eq 200
        system.reload!
        seen = system.signage_last_seen

        headers["If-Modified-Since"] = result.headers["Last-Modified"]
        client.get(path: "#{Signage.base_route}/#{system_id}?preview=false", headers: headers).status_code.should eq 304
        system.reload!
        system.signage_last_seen.should be >= seen
      end
    end
  end
end
