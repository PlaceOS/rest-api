require "../helper"
require "timecop"

module PlaceOS::Api
  describe Signage do
    ::Spec.before_each do
      Model::Playlist::Revision.clear
      Model::Playlist::Item.clear
      Model::Playlist.clear
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

      it "POST /api/engine/v2/signage/:system_id/metrics" do
        revision = Model::Generator.revision

        item = Model::Generator.item
        item.save!
        item1_id = item.id.as(String)
        item2 = Model::Generator.item
        item2.save!
        item2_id = item2.id.as(String)

        revision.items = [item1_id, item2_id]
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
    end
  end
end
