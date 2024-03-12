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
      it "GET /:system_id" do
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
    end
  end
end
