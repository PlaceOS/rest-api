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

      it "?group_id= scopes admins to items linked to that group (SQL subquery)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        group = Model::Generator.group(authority: authority).save!

        linked = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: group, playlist_item: linked).save!
        _unlinked = Model::Generator.item(authority: authority).save!

        result = client.get("#{base}?group_id=#{group.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [linked.id.to_s]
      end

      it "spans multiple readable groups for a regular user (multi-placeholder IN)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root = Model::Generator.group(authority: authority).save!
        group_a = Model::Generator.group(authority: authority, parent: root).save!
        group_b = Model::Generator.group(authority: authority, parent: root).save!
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Read).save!
        Model::Generator.group_user(user: user, group: group_b, permissions: Model::Permissions::Read).save!

        in_a = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: group_a, playlist_item: in_a).save!
        in_b = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: group_b, playlist_item: in_b).save!
        _hidden = Model::Generator.item(authority: authority).save!

        result = client.get(base, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.sort.should eq [in_a.id.to_s, in_b.id.to_s].sort
      end

      it "?tags= and group scope combine (tags filter + subquery + authority)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        promo = Model::Generator.item(authority: authority)
        promo.tags = Set{"promo"}
        promo.save!
        Model::Generator.group_playlist_item(group: group, playlist_item: promo).save!

        # same tag, but not linked to the user's group -> excluded by scope
        promo_unlinked = Model::Generator.item(authority: authority)
        promo_unlinked.tags = Set{"promo"}
        promo_unlinked.save!

        # linked to the group, but different tag -> excluded by tag filter
        other = Model::Generator.item(authority: authority)
        other.tags = Set{"lobby"}
        other.save!
        Model::Generator.group_playlist_item(group: group, playlist_item: other).save!

        result = client.get("#{base}?tags=promo", headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [promo.id.to_s]
      end

      it "?tags= returns items carrying any of the supplied tags" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        promo = Model::Generator.item(authority: authority)
        promo.tags = Set{"promo", "lobby"}
        promo.save!

        lobby = Model::Generator.item(authority: authority)
        lobby.tags = Set{"lobby"}
        lobby.save!

        other = Model::Generator.item(authority: authority)
        other.tags = Set{"warehouse"}
        other.save!

        result = client.get("#{base}?tags=promo,warehouse", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(promo.id.to_s)
        ids.should contain(other.id.to_s)
        ids.should_not contain(lobby.id.to_s)
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

    describe "GET /tags" do
      it "admin sees the distinct tags across all media in the authority (sorted)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        a = Model::Generator.item(authority: authority)
        a.tags = Set{"zebra", "alpha"}
        a.save!

        b = Model::Generator.item(authority: authority)
        b.tags = Set{"alpha", "mango"}
        b.save!

        result = client.get("#{base}/tags", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        Array(String).from_json(result.body).should eq ["alpha", "mango", "zebra"]
      end

      it "returns an empty list when no media is tagged" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        Model::Generator.item(authority: authority).save!

        result = client.get("#{base}/tags", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        Array(String).from_json(result.body).should eq [] of String
      end

      it "?group_id= scopes tags to media linked to that group" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        group = Model::Generator.group(authority: authority).save!

        linked = Model::Generator.item(authority: authority)
        linked.tags = Set{"in-group"}
        linked.save!
        Model::Generator.group_playlist_item(group: group, playlist_item: linked).save!

        unlinked = Model::Generator.item(authority: authority)
        unlinked.tags = Set{"out-of-group"}
        unlinked.save!

        result = client.get("#{base}/tags?group_id=#{group.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        Array(String).from_json(result.body).should eq ["in-group"]
      end

      it "scopes a regular user to tags from media in groups they can read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        mine = Model::Generator.item(authority: authority)
        mine.tags = Set{"mine"}
        mine.save!
        Model::Generator.group_playlist_item(group: group, playlist_item: mine).save!

        hidden = Model::Generator.item(authority: authority)
        hidden.tags = Set{"hidden"}
        hidden.save!

        result = client.get("#{base}/tags", headers: headers)
        result.status_code.should eq 200
        Array(String).from_json(result.body).should eq ["mine"]
      end

      it "rejects a regular user requesting tags for a group they can't read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!

        result = client.get("#{base}/tags?group_id=#{group.id}", headers: headers)
        result.status_code.should eq 403
      end
    end

    describe "POST /share" do
      it "admin shares items into a signage group, skipping duplicates" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!

        a = Model::Generator.item(authority: authority).save!
        b = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: target, playlist_item: b).save!

        params = HTTP::Params.encode({"items" => "#{a.id},#{b.id}", "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.success?.should be_true

        body = JSON.parse(result.body)
        body["linked"].as_a.map(&.as_s).should eq [a.id.to_s]
        body["already_present"].as_a.map(&.as_s).should eq [b.id.to_s]

        target_id = target.id.as(UUID)
        Model::GroupPlaylistItem.find?({target_id, a.id.as(String)}).should_not be_nil
        Model::GroupPlaylistItem.find?({target_id, b.id.as(String)}).should_not be_nil
      end

      it "rejects when target group lacks the 'signage' subsystem" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.group(authority: authority, subsystems: ["events"]).save!
        item = Model::Generator.item(authority: authority).save!

        params = HTTP::Params.encode({"items" => item.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 403
      end

      it "404s when an item belongs to a different authority" do
        own = Model::Authority.find_by_domain("localhost").not_nil!
        other = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        target = Model::Generator.group(authority: own, subsystems: ["signage"]).save!

        local_item = Model::Generator.item(authority: own).save!
        foreign_item = Model::Generator.item(authority: other).save!

        params = HTTP::Params.encode({"items" => "#{local_item.id},#{foreign_item.id}", "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end

      it "lets a user with Share + Read permissions share into a group they belong to" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root = Model::Generator.group(authority: authority).save!
        source = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!
        target = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!

        Model::Generator.group_user(user: user, group: source, permissions: Model::Permissions::Read).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Read | Model::Permissions::Share).save!

        item = Model::Generator.item(authority: authority).save!
        Model::Generator.group_playlist_item(group: source, playlist_item: item).save!

        params = HTTP::Params.encode({"items" => item.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.success?.should be_true
        Model::GroupPlaylistItem.find?({target.id.as(UUID), item.id.as(String)}).should_not be_nil
      end

      it "rejects a regular user trying to share an item they can't read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Share).save!

        admin_only = Model::Generator.item(authority: authority).save!

        params = HTTP::Params.encode({"items" => admin_only.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.status_code.should eq 403
      end
    end
  end
end
