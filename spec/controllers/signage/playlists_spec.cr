require "../../helper"

module PlaceOS::Api
  describe Playlist do
    base = Playlist.base_route

    ::Spec.before_each do
      Model::Playlist::Revision.clear
      Model::Playlist::Item.clear
      Model::Playlist.clear
      clear_group_tables
    end

    describe "CRUD as admin/support" do
      it "admin can create an unlinked playlist (no group_id) and see it in index" do
        body = Model::Generator.playlist.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 201
        playlist = Model::Playlist.from_trusted_json(result.body)
        Model::Playlist.find?(playlist.id.not_nil!).should_not be_nil

        index = client.get(base, headers: Spec::Authentication.headers)
        index.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(index.body).map(&.["id"].as_s)
        ids.should contain(playlist.id.to_s)
      end

      it "admin can update and destroy a playlist" do
        playlist = Model::Generator.playlist.save!

        update = client.patch(
          File.join(base, playlist.id.to_s),
          body: {name: "renamed-by-admin"}.to_json,
          headers: Spec::Authentication.headers,
        )
        update.status_code.should eq 200

        delete = client.delete(File.join(base, playlist.id.to_s), headers: Spec::Authentication.headers)
        delete.success?.should be_true
      end
    end

    describe "regular users via group membership" do
      it "can view a playlist linked to a group they have Read on" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: group, playlist: playlist).save!

        show = client.get(File.join(base, playlist.id.to_s), headers: headers)
        show.status_code.should eq 200
      end

      it "cannot view a playlist with no group links (admin-only visibility)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        playlist = Model::Generator.playlist(authority: authority).save!
        show = client.get(File.join(base, playlist.id.to_s), headers: headers)
        show.status_code.should eq 403
      end

      it "cannot update without Update permission on any linked group" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: group, playlist: playlist).save!

        result = client.patch(
          File.join(base, playlist.id.to_s),
          body: {name: "trying"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403
      end

      it "can update with Update permission" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Update
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: group, playlist: playlist).save!

        result = client.patch(
          File.join(base, playlist.id.to_s),
          body: {name: "renamed-by-user"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 200
      end

      it "create requires group_id + Create permission, and auto-links the new playlist" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Create
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        body = Model::Generator.playlist(authority: authority).to_json

        # missing group_id → 403
        missing = client.post(base, body: body, headers: headers)
        missing.status_code.should eq 403

        # with group_id → 201 + junction row created
        result = client.post("#{base}?group_id=#{group.id}", body: body, headers: headers)
        result.status_code.should eq 201
        created = Model::Playlist.from_trusted_json(result.body)
        Model::GroupPlaylist.find?({group.id.not_nil!, created.id.not_nil!}).should_not be_nil
      end
    end

    describe "index filtering" do
      it "scopes non-admin callers to playlists linked to their groups" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        mine = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: group, playlist: mine).save!
        _hidden = Model::Generator.playlist(authority: authority).save!

        result = client.get(base, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [mine.id.to_s]
      end

      it "?group_id= returns playlists linked to that group for users with Read on it" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        mine = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: group, playlist: mine).save!

        result = client.get("#{base}?group_id=#{group.id}", headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(mine.id.to_s)
      end

      it "?group_id= is 403 without Read permission" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        group = Model::Generator.group(authority: authority).save!
        result = client.get("#{base}?group_id=#{group.id}", headers: headers)
        result.status_code.should eq 403
      end

      it "?q= searches name and description (ILIKE)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        hit_name = Model::Generator.playlist(authority: authority)
        hit_name.name = "Lobby-signs-#{Random::Secure.hex(3)}"
        hit_name.save!

        hit_desc = Model::Generator.playlist(authority: authority)
        hit_desc.description = "Used in the lobby during holidays"
        hit_desc.save!

        miss = Model::Generator.playlist(authority: authority)
        miss.name = "cafeteria-#{Random::Secure.hex(3)}"
        miss.description = "cafeteria only"
        miss.save!

        result = client.get("#{base}?q=lobby", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(hit_name.id.to_s)
        ids.should contain(hit_desc.id.to_s)
        ids.should_not contain(miss.id.to_s)
      end
    end
  end
end
