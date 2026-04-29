require "../../helper"

module PlaceOS::Api
  describe PlaylistMedia do
    base = PlaylistMedia.base_route

    ::Spec.before_each do
      Model::Playlist::Item.clear
      Model::Playlist.clear
      clear_group_tables
    end

    describe "CRUD as admin/support" do
      it "admin can create an unlinked item and list it" do
        body = Model::Generator.item.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 201
        item = Model::Playlist::Item.from_trusted_json(result.body)
        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil

        index = client.get(base, headers: Spec::Authentication.headers)
        index.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(index.body).map(&.["id"].as_s)
        ids.should contain(item.id.to_s)
      end
    end

    describe "regular users via group membership" do
      it "can view an item linked to a group they have Read on" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        item = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: group, playlist_item: item).save!

        show = client.get(File.join(base, item.id.to_s), headers: headers)
        show.status_code.should eq 200
      end

      it "cannot view an unlinked item (admin-only visibility)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        item = Model::Generator.item(authority: authority).save!
        show = client.get(File.join(base, item.id.to_s), headers: headers)
        show.status_code.should eq 403
      end

      it "create auto-links via GroupPlaylistItem when group_id + Create perm" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Create
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        body = Model::Generator.item(authority: authority).to_json

        missing = client.post(base, body: body, headers: headers)
        missing.status_code.should eq 403

        result = client.post("#{base}?group_id=#{group.id}", body: body, headers: headers)
        result.status_code.should eq 201
        created = Model::Playlist::Item.from_trusted_json(result.body)
        Model::GroupPlaylistItem.find?({group.id.not_nil!, created.id.not_nil!}).should_not be_nil
      end

      it "cannot destroy without Delete permission" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        item = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: group, playlist_item: item).save!

        result = client.delete(File.join(base, item.id.to_s), headers: headers)
        result.status_code.should eq 403
      end
    end

    describe "index filtering" do
      it "scopes non-admin callers to items linked to their groups" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        mine = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: group, playlist_item: mine).save!
        _hidden = Model::Generator.item(authority: authority).save!

        result = client.get(base, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [mine.id.to_s]
      end

      it "?q= searches name and description (ILIKE)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        hit_name = Model::Generator.item(authority: authority)
        hit_name.name = "Welcome-sign-#{Random::Secure.hex(3)}"
        hit_name.save!

        hit_desc = Model::Generator.item(authority: authority)
        hit_desc.description = "Welcomes guests at the entrance"
        hit_desc.save!

        miss = Model::Generator.item(authority: authority)
        miss.name = "back-room-#{Random::Secure.hex(3)}"
        miss.description = "internal only"
        miss.save!

        result = client.get("#{base}?q=welcome", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(hit_name.id.to_s)
        ids.should contain(hit_desc.id.to_s)
        ids.should_not contain(miss.id.to_s)
      end
    end
  end
end
