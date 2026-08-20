require "../../helper"

module PlaceOS::Api
  # Two groups sharing one media item: `group_a` and `group_b`, both children
  # of the authority root `parent_a`. Returns (authority, item, parent_a, group_a, group_b).
  def self.setup_shared_media
    authority = Model::Authority.find_by_domain("localhost").not_nil!
    # an authority has a single root group; everything else hangs off it
    parent_a = Model::Generator.group(authority: authority).save!
    group_a = Model::Generator.group(authority: authority, parent: parent_a).save!
    group_b = Model::Generator.group(authority: authority, parent: parent_a).save!

    item = Model::Generator.item(authority: authority).save!
    Model::Generator.group_playlist_item(group: group_a, playlist_item: item).save!
    Model::Generator.group_playlist_item(group: group_b, playlist_item: item).save!

    {authority, item, parent_a, group_a, group_b}
  end

  def self.media_link?(group, item) : Bool
    !Model::GroupPlaylistItem.find?({group.id.not_nil!, item.id.not_nil!}).nil?
  end

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
      it "returns newest items first" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        oldest = Model::Generator.item(authority: authority).save!
        middle = Model::Generator.item(authority: authority).save!
        newest = Model::Generator.item(authority: authority).save!

        result = client.get(base, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [newest.id.to_s, middle.id.to_s, oldest.id.to_s]
      end

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

    describe "GET /tag_counts" do
      it "returns per-tag item counts for the authority (admin)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        a = Model::Generator.item(authority: authority)
        a.tags = Set{"promo", "lobby"}
        a.save!
        b = Model::Generator.item(authority: authority)
        b.tags = Set{"promo"}
        b.save!
        c = Model::Generator.item(authority: authority)
        c.tags = Set(String).new
        c.save!

        result = client.get("#{base}/tag_counts", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        counts = Hash(String, Int32).from_json(result.body)
        counts.should eq({"lobby" => 1, "promo" => 2})
      end

      it "scopes non-admin callers to media in groups they can read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        mine = Model::Generator.item(authority: authority)
        mine.tags = Set{"promo"}
        mine.save!
        Model::Generator.group_playlist_item(group: group, playlist_item: mine).save!

        hidden = Model::Generator.item(authority: authority)
        hidden.tags = Set{"promo", "secret"}
        hidden.save!

        result = client.get("#{base}/tag_counts", headers: headers)
        result.status_code.should eq 200
        counts = Hash(String, Int32).from_json(result.body)
        counts.should eq({"promo" => 1})
      end

      it "?group_id= scopes to one group and is 403 without Read on it" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root = Model::Generator.group(authority: authority).save!
        group_a = Model::Generator.group(authority: authority, parent: root).save!
        group_b = Model::Generator.group(authority: authority, parent: root).save!
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Read).save!

        in_a = Model::Generator.item(authority: authority)
        in_a.tags = Set{"lobby"}
        in_a.save!
        Model::Generator.group_playlist_item(group: group_a, playlist_item: in_a).save!

        in_b = Model::Generator.item(authority: authority)
        in_b.tags = Set{"lobby", "promo"}
        in_b.save!
        Model::Generator.group_playlist_item(group: group_b, playlist_item: in_b).save!

        result = client.get("#{base}/tag_counts?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 200
        counts = Hash(String, Int32).from_json(result.body)
        counts.should eq({"lobby" => 1})

        forbidden = client.get("#{base}/tag_counts?group_id=#{group_b.id}", headers: headers)
        forbidden.status_code.should eq 403
      end

      it "returns an empty hash for a user with no group memberships" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        tagged = Model::Generator.item(authority: authority)
        tagged.tags = Set{"promo"}
        tagged.save!

        result = client.get("#{base}/tag_counts", headers: headers)
        result.status_code.should eq 200
        Hash(String, Int32).from_json(result.body).should be_empty
      end
    end

    describe "shared_with on show" do
      it "lists every group the item is shared with" do
        _, item, _, group_a, group_b = setup_shared_media

        show = client.get(File.join(base, item.id.to_s), headers: Spec::Authentication.headers)
        show.status_code.should eq 200

        shared = JSON.parse(show.body)["shared_with"].as_a
        shared.map(&.["id"].as_s).sort!.should eq [group_a.id.to_s, group_b.id.to_s].sort!
        shared.map(&.["name"].as_s).sort!.should eq [group_a.name, group_b.name].sort!
      end

      it "includes groups the caller is not a member of" do
        _, item, _, group_a, group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Read).save!

        show = client.get(File.join(base, item.id.to_s), headers: headers)
        show.status_code.should eq 200
        JSON.parse(show.body)["shared_with"].as_a.map(&.["id"].as_s).sort!
          .should eq [group_a.id.to_s, group_b.id.to_s].sort!
      end

      it "is an empty array for an unlinked item" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        item = Model::Generator.item(authority: authority).save!

        show = client.get(File.join(base, item.id.to_s), headers: Spec::Authentication.headers)
        show.status_code.should eq 200
        JSON.parse(show.body)["shared_with"].as_a.should be_empty
      end

      it "is not present on index results" do
        _, item, _, _, _ = setup_shared_media

        index = client.get(base, headers: Spec::Authentication.headers)
        index.status_code.should eq 200
        listed = Array(JSON::Any).from_json(index.body).find { |i| i["id"].as_s == item.id.to_s }
        listed.should_not be_nil
        listed.not_nil!.as_h.has_key?("shared_with").should be_false
      end
    end

    describe "DELETE /:id?group_id= (unlink from a single group)" do
      it "admin unlinks the item from one group; the item and its other links remain" do
        _authority, item, _parent_a, group_a, group_b = setup_shared_media

        result = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 202

        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil
        media_link?(group_a, item).should be_false
        media_link?(group_b, item).should be_true
      end

      it "a user with Delete on the group can unlink (without needing rights on other linked groups)" do
        _authority, item, _parent_a, group_a, group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Delete).save!

        # a full delete would need Delete via a linked group too — this user
        # has it, but the item is also in group_b which they know nothing about
        result = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 202

        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil
        media_link?(group_a, item).should be_false
        media_link?(group_b, item).should be_true
      end

      it "Delete inherited from a parent group unlinks from the child group" do
        _authority, item, parent_a, group_a, group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: parent_a, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 202

        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil
        media_link?(group_a, item).should be_false
        media_link?(group_b, item).should be_true
      end

      it "Manage on the group also permits unlinking" do
        _authority, item, _parent_a, group_a, _group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Manage).save!

        result = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 202
        media_link?(group_a, item).should be_false
      end

      it "is 403 without Delete or Manage on the group (link kept)" do
        _authority, item, _parent_a, group_a, _group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        perms = Model::Permissions::Read | Model::Permissions::Update | Model::Permissions::Share
        Model::Generator.group_user(user: user, group: group_a, permissions: perms).save!

        result = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 403
        media_link?(group_a, item).should be_true
      end

      it "is 403 when the user's Delete is on a different group than the one specified" do
        _authority, item, _parent_a, group_a, group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_b, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 403
        media_link?(group_a, item).should be_true
        media_link?(group_b, item).should be_true
      end

      it "is 404 when the item is not linked to the specified group" do
        authority, item, parent_a, group_a, group_b = setup_shared_media
        other = Model::Generator.group(authority: authority, parent: parent_a).save!

        result = client.delete("#{base}/#{item.id}?group_id=#{other.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404

        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil
        media_link?(group_a, item).should be_true
        media_link?(group_b, item).should be_true
      end

      it "is 404 for an unknown group or a group in another authority" do
        _authority, item, _parent_a, _group_a, _group_b = setup_shared_media

        result = client.delete("#{base}/#{item.id}?group_id=#{UUID.random}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404

        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        foreign = Model::Generator.group(authority: other_authority).save!
        result = client.delete("#{base}/#{item.id}?group_id=#{foreign.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404
        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil
      end

      it "deletes the item outright when the last group link is removed" do
        _authority, item, _parent_a, group_a, group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Delete).save!
        Model::Generator.group_user(user: user, group: group_b, permissions: Model::Permissions::Delete).save!

        first = client.delete("#{base}/#{item.id}?group_id=#{group_a.id}", headers: headers)
        first.status_code.should eq 202
        Model::Playlist::Item.find?(item.id.not_nil!).should_not be_nil

        last = client.delete("#{base}/#{item.id}?group_id=#{group_b.id}", headers: headers)
        last.status_code.should eq 202
        Model::Playlist::Item.find?(item.id.not_nil!).should be_nil
        media_link?(group_b, item).should be_false
      end

      it "without group_id a user with Delete on a linked group still deletes the item outright" do
        _authority, item, _parent_a, group_a, group_b = setup_shared_media
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{item.id}", headers: headers)
        result.status_code.should eq 202

        Model::Playlist::Item.find?(item.id.not_nil!).should be_nil
        media_link?(group_a, item).should be_false
        media_link?(group_b, item).should be_false
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
