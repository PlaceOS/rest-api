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

    describe "POST /share" do
      it "admin shares playlists into a signage group, skipping duplicates" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!

        a = Model::Generator.playlist(authority: authority).save!
        b = Model::Generator.playlist(authority: authority).save!

        # `b` is already linked — should be reported as already_present.
        Model::Generator.group_playlist(group: target, playlist: b).save!

        params = HTTP::Params.encode({"items" => "#{a.id},#{b.id}", "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.success?.should be_true

        body = JSON.parse(result.body)
        body["linked"].as_a.map(&.as_s).should eq [a.id.to_s]
        body["already_present"].as_a.map(&.as_s).should eq [b.id.to_s]

        target_id = target.id.as(UUID)
        Model::GroupPlaylist.find?({target_id, a.id.as(String)}).should_not be_nil
        Model::GroupPlaylist.find?({target_id, b.id.as(String)}).should_not be_nil
      end

      it "rejects when target group lacks the 'signage' subsystem" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.group(authority: authority, subsystems: ["events"]).save!
        playlist = Model::Generator.playlist(authority: authority).save!

        params = HTTP::Params.encode({"items" => playlist.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 403
      end

      it "rejects when target group is in a different authority" do
        own = Model::Authority.find_by_domain("localhost").not_nil!
        other = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        foreign_target = Model::Generator.group(authority: other, subsystems: ["signage"]).save!
        playlist = Model::Generator.playlist(authority: own).save!

        params = HTTP::Params.encode({"items" => playlist.id.to_s, "to" => foreign_target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 403
      end

      it "404s when an item belongs to a different authority" do
        own = Model::Authority.find_by_domain("localhost").not_nil!
        other = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        target = Model::Generator.group(authority: own, subsystems: ["signage"]).save!

        local_pl = Model::Generator.playlist(authority: own).save!
        foreign_pl = Model::Generator.playlist(authority: other).save!

        params = HTTP::Params.encode({"items" => "#{local_pl.id},#{foreign_pl.id}", "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end

      it "lets a user with Share + Read permissions share into a group they belong to" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        # One root per authority — source/target sit beneath it.
        root = Model::Generator.group(authority: authority).save!
        source = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!
        target = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!

        Model::Generator.group_user(user: user, group: source, permissions: Model::Permissions::Read).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Read | Model::Permissions::Share).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: source, playlist: playlist).save!

        params = HTTP::Params.encode({"items" => playlist.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.success?.should be_true
        Model::GroupPlaylist.find?({target.id.as(UUID), playlist.id.as(String)}).should_not be_nil
      end

      it "rejects a user without Share or Manage on the target group" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Read).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: target, playlist: playlist).save!

        # Use a *different* unlinked playlist so the failure is the
        # missing Share, not lack of read.
        other_playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: target, playlist: other_playlist).save!

        params = HTTP::Params.encode({"items" => playlist.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.status_code.should eq 403
      end

      it "rejects a regular user trying to share a playlist they can't read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Share).save!

        # Admin-only playlist (no GroupPlaylist rows).
        admin_only = Model::Generator.playlist(authority: authority).save!

        params = HTTP::Params.encode({"items" => admin_only.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.status_code.should eq 403
      end
    end

    describe "GET /:id/media and /:id/media/revisions" do
      it "returns the latest revision with media hydrated for a playlist Reader, even when items aren't shared with their group" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        # Reader has access to the playlist via this group only — items are NOT linked here.
        reader_group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: reader_group, permissions: Model::Permissions::Read).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: reader_group, playlist: playlist).save!

        # Items are admin-only (no GroupPlaylistItem rows) — they were created by an
        # admin / another team and should still be visible to the reader because they
        # belong to a playlist the reader can access.
        item_a = Model::Generator.item(authority: authority).save!
        item_b = Model::Generator.item(authority: authority).save!

        author = Model::Generator.user(authority: authority).save!
        revision = Model::Generator.revision(playlist: playlist, user: author)
        revision.items = [item_a.id.as(String), item_b.id.as(String)]
        revision.save!

        result = client.get(File.join(base, playlist.id.to_s, "media"), headers: headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body).as_h
        body["items"].as_a.map(&.as_s).sort!.should eq [item_a.id.to_s, item_b.id.to_s].sort
        body["media"].should_not be_nil
        media_ids = body["media"].as_a.map(&.as_h.["id"].as_s).sort!
        media_ids.should eq [item_a.id.to_s, item_b.id.to_s].sort
      end

      it "returns all revisions with media hydrated for a playlist Reader" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        reader_group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: reader_group, permissions: Model::Permissions::Read).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: reader_group, playlist: playlist).save!

        item_a = Model::Generator.item(authority: authority).save!
        item_b = Model::Generator.item(authority: authority).save!

        author = Model::Generator.user(authority: authority).save!
        first = Model::Generator.revision(playlist: playlist, user: author)
        first.items = [item_a.id.as(String)]
        first.approved = true
        first.save!

        second = Model::Generator.revision(playlist: playlist, user: author)
        second.items = [item_a.id.as(String), item_b.id.as(String)]
        second.save!

        result = client.get(File.join(base, playlist.id.to_s, "media", "revisions"), headers: headers)
        result.status_code.should eq 200

        revisions = JSON.parse(result.body).as_a.map(&.as_h)
        revisions.size.should be >= 1
        revisions.each do |rev|
          rev["media"].should_not be_nil
          item_ids = rev["items"].as_a.map(&.as_s).sort!
          media_ids = rev["media"].as_a.map(&.as_h.["id"].as_s).sort!
          media_ids.should eq item_ids
        end
      end

      it "returns an empty media array when the playlist has no revisions" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        reader_group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: reader_group, permissions: Model::Permissions::Read).save!

        playlist = Model::Generator.playlist(authority: authority).save!
        Model::Generator.group_playlist(group: reader_group, playlist: playlist).save!

        result = client.get(File.join(base, playlist.id.to_s, "media"), headers: headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body).as_h
        body["items"].as_a.should be_empty
        body["media"].as_a.should be_empty
      end
    end

    describe "approval requests" do
      ::Spec.before_each { Model::PendingMail.clear }

      describe "GET /approvers" do
        it "returns approve and manage users (not read-only members)" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          group = Model::Generator.group(authority: authority).save!

          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!
          manager = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: manager, group: group, permissions: Model::Permissions::Manage).save!
          reader = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: reader, group: group, permissions: Model::Permissions::Read).save!

          result = client.get("#{base}/approvers?group_id=#{group.id}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(approver.id)
          ids.should contain(manager.id)
          ids.should_not contain(reader.id)
        end

        it "climbs to the parent group when the child has no approver" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          parent = Model::Generator.group(authority: authority).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: parent, permissions: Model::Permissions::Approve).save!

          child = Model::Generator.group(authority: authority)
          child.parent_id = parent.id
          child.save!
          reader = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: reader, group: child, permissions: Model::Permissions::Read).save!

          result = client.get("#{base}/approvers?group_id=#{child.id}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(approver.id)
        end

        it "includes managers from intermediate groups plus the parent's approvers" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          parent = Model::Generator.group(authority: authority).save!
          parent_approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: parent_approver, group: parent, permissions: Model::Permissions::Approve).save!

          child = Model::Generator.group(authority: authority)
          child.parent_id = parent.id
          child.save!
          child_manager = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: child_manager, group: child, permissions: Model::Permissions::Manage).save!
          child_reader = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: child_reader, group: child, permissions: Model::Permissions::Read).save!

          result = client.get("#{base}/approvers?group_id=#{child.id}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
          ids.should contain(child_manager.id)
          ids.should contain(parent_approver.id)
          ids.should_not contain(child_reader.id)
        end

        it "returns an empty list when no approver exists up the tree" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          group = Model::Generator.group(authority: authority).save!
          reader = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: reader, group: group, permissions: Model::Permissions::Read).save!

          result = client.get("#{base}/approvers?group_id=#{group.id}", headers: Spec::Authentication.headers)
          result.status_code.should eq 200
          Array(JSON::Any).from_json(result.body).should be_empty
        end

        it "forbids a non-member, non-support caller" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          group = Model::Generator.group(authority: authority).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!

          _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
          result = client.get("#{base}/approvers?group_id=#{group.id}", headers: headers)
          result.status_code.should eq 403
        end
      end

      describe "POST /:id/media/request_approval" do
        it "queues a PendingMail to the group's approvers" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!
          zone = Model::Generator.zone.save!
          Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

          playlist = Model::Generator.playlist(authority: authority).save!
          # request_approval requires the playlist to have a media revision
          item = Model::Generator.item(authority: authority).save!
          revision = Model::Generator.revision(playlist: playlist, user: user)
          revision.items = [item.id.as(String)]
          revision.save!

          result = client.post(
            "#{base}/#{playlist.id}/media/request_approval?group_id=#{group.id}",
            body: {message: "please review"}.to_json,
            headers: headers,
          )
          result.success?.should be_true

          mail = Model::PendingMail.where(source_reference: "playlist-#{playlist.id}").to_a.first.not_nil!
          mail.send_to.should contain(approver.email.to_s)
          mail.template.should eq ["signage", "request_playlist_approval"]
          mail.source_service.should eq "signage"
          mail.zones.should contain(zone.id)
          mail.args["message"].should eq "please review"
          mail.args["group_id"].should eq group.id.to_s
          mail.args["group_name"].should eq group.name
          mail.args["playlist_id"].should eq playlist.id
          mail.expiry.should_not be_nil

          zone.destroy
        end

        it "notifies only the selected approver_id (a manager is allowed)" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!
          manager = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: manager, group: group, permissions: Model::Permissions::Manage).save!

          playlist = Model::Generator.playlist(authority: authority).save!
          # request_approval requires the playlist to have a media revision
          item = Model::Generator.item(authority: authority).save!
          revision = Model::Generator.revision(playlist: playlist, user: user)
          revision.items = [item.id.as(String)]
          revision.save!

          result = client.post(
            "#{base}/#{playlist.id}/media/request_approval?group_id=#{group.id}&approver_id=#{manager.id}",
            body: {message: ""}.to_json,
            headers: headers,
          )
          result.success?.should be_true

          mail = Model::PendingMail.where(source_reference: "playlist-#{playlist.id}").to_a.first.not_nil!
          mail.send_to.should eq [manager.email.to_s]
        end

        it "allows selecting a manager from an intermediate group" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          parent = Model::Generator.group(authority: authority).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: parent, permissions: Model::Permissions::Approve).save!

          child = Model::Generator.group(authority: authority)
          child.parent_id = parent.id
          child.save!
          Model::Generator.group_user(user: user, group: child, permissions: Model::Permissions::Read).save!
          manager = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: manager, group: child, permissions: Model::Permissions::Manage).save!

          playlist = Model::Generator.playlist(authority: authority).save!
          # request_approval requires the playlist to have a media revision
          item = Model::Generator.item(authority: authority).save!
          revision = Model::Generator.revision(playlist: playlist, user: user)
          revision.items = [item.id.as(String)]
          revision.save!

          result = client.post(
            "#{base}/#{playlist.id}/media/request_approval?group_id=#{child.id}&approver_id=#{manager.id}",
            body: {message: ""}.to_json,
            headers: headers,
          )
          result.success?.should be_true

          mail = Model::PendingMail.where(source_reference: "playlist-#{playlist.id}").to_a.first.not_nil!
          mail.send_to.should eq [manager.email.to_s]
        end

        it "returns 406 when the group has no approvers up the tree" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

          playlist = Model::Generator.playlist(authority: authority).save!

          result = client.post(
            "#{base}/#{playlist.id}/media/request_approval?group_id=#{group.id}",
            body: {message: "hi"}.to_json,
            headers: headers,
          )
          result.status_code.should eq 406
        end

        it "returns 406 when approver_id is not an approver or manager" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!
          bystander = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: bystander, group: group, permissions: Model::Permissions::Read).save!

          playlist = Model::Generator.playlist(authority: authority).save!

          result = client.post(
            "#{base}/#{playlist.id}/media/request_approval?group_id=#{group.id}&approver_id=#{bystander.id}",
            body: {message: "hi"}.to_json,
            headers: headers,
          )
          result.status_code.should eq 406
        end

        it "forbids a caller who is not a member of the group or a parent" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!

          playlist = Model::Generator.playlist(authority: authority).save!

          result = client.post(
            "#{base}/#{playlist.id}/media/request_approval?group_id=#{group.id}",
            body: {message: "hi"}.to_json,
            headers: headers,
          )
          result.status_code.should eq 403
        end
      end
    end
  end
end
