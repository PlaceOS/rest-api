require "../../helper"

module PlaceOS::Api
  # Two groups sharing one template: `group_a` and `group_b`, both children
  # of the authority root `parent_a`. Returns (authority, template, parent_a, group_a, group_b).
  def self.setup_shared_template
    authority = Model::Authority.find_by_domain("localhost").not_nil!
    # an authority has a single root group; everything else hangs off it
    parent_a = Model::Generator.group(authority: authority).save!
    group_a = Model::Generator.group(authority: authority, parent: parent_a).save!
    group_b = Model::Generator.group(authority: authority, parent: parent_a).save!

    template = Model::Generator.signage_template(authority: authority).save!
    Model::Generator.group_signage_template(group: group_a, signage_template: template).save!
    Model::Generator.group_signage_template(group: group_b, signage_template: template).save!

    {authority, template, parent_a, group_a, group_b}
  end

  def self.template_link?(group, template) : Bool
    !Model::GroupSignageTemplate.find?({group.id.not_nil!, template.id.not_nil!}).nil?
  end

  describe SignageTemplates do
    base = SignageTemplates.base_route

    ::Spec.before_each do
      Model::SignageTemplate::SystemTemplate.clear
      Model::SignageTemplate.clear
      clear_group_tables
    end

    describe "CRUD as admin/support" do
      it "admin can create an unlinked template (no group_id) and see it in index" do
        body = Model::Generator.signage_template.to_json
        result = client.post(base, body: body, headers: Spec::Authentication.headers)
        result.status_code.should eq 201
        template = Model::SignageTemplate.from_trusted_json(result.body)
        Model::SignageTemplate.find?(template.id.not_nil!).should_not be_nil
        template.approved.should be_false

        index = client.get(base, headers: Spec::Authentication.headers)
        index.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(index.body).map(&.["id"].as_s)
        ids.should contain(template.id.to_s)
      end

      it "admin can update and destroy a template" do
        template = Model::Generator.signage_template.save!

        update = client.patch(
          File.join(base, template.id.to_s),
          body: {name: "renamed-by-admin"}.to_json,
          headers: Spec::Authentication.headers,
        )
        update.status_code.should eq 200

        delete = client.delete(File.join(base, template.id.to_s), headers: Spec::Authentication.headers)
        delete.success?.should be_true
      end

      it "404s for an unknown template id" do
        result = client.get(File.join(base, UUID.random.to_s), headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end
    end

    describe "regular users via group membership" do
      it "can view a template linked to a group they have Read on" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!

        show = client.get(File.join(base, template.id.to_s), headers: headers)
        show.status_code.should eq 200
      end

      it "cannot view a template with no group links (admin-only visibility)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        template = Model::Generator.signage_template(authority: authority).save!
        show = client.get(File.join(base, template.id.to_s), headers: headers)
        show.status_code.should eq 403
      end

      it "cannot update without Update permission on any linked group" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!

        result = client.patch(
          File.join(base, template.id.to_s),
          body: {name: "trying"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 403

        discard = client.delete(File.join(base, template.id.to_s, "draft"), headers: headers)
        discard.status_code.should eq 403
      end

      it "can update with Update permission" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Update
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!

        result = client.patch(
          File.join(base, template.id.to_s),
          body: {name: "renamed-by-user"}.to_json,
          headers: headers,
        )
        result.status_code.should eq 200
      end

      it "cannot approve without Approve permission" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Update
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!

        result = client.post(File.join(base, template.id.to_s, "approve"), headers: headers)
        result.status_code.should eq 403
      end

      it "can approve with Approve permission" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Approve
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: template).save!

        result = client.post(File.join(base, template.id.to_s, "approve"), headers: headers)
        result.status_code.should eq 200

        found = Model::SignageTemplate.find!(template.id.as(UUID))
        found.approved.should be_true
        found.approved_by_id.should eq user.id
      end

      it "create requires group_id + Create permission, and auto-links the new template" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        perms = Model::Permissions::Read | Model::Permissions::Create
        Model::Generator.group_user(user: user, group: group, permissions: perms).save!

        body = Model::Generator.signage_template(authority: authority).to_json

        # missing group_id → 403
        missing = client.post(base, body: body, headers: headers)
        missing.status_code.should eq 403

        # with group_id → 201 + junction row created
        result = client.post("#{base}?group_id=#{group.id}", body: body, headers: headers)
        result.status_code.should eq 201
        created = Model::SignageTemplate.from_trusted_json(result.body)
        Model::GroupSignageTemplate.find?({group.id.not_nil!, created.id.not_nil!}).should_not be_nil
      end
    end

    describe "index filtering" do
      it "returns newest templates first" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        oldest = Model::Generator.signage_template(authority: authority).save!
        middle = Model::Generator.signage_template(authority: authority).save!
        newest = Model::Generator.signage_template(authority: authority).save!

        result = client.get(base, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [newest.id.to_s, middle.id.to_s, oldest.id.to_s]
      end

      it "scopes non-admin callers to templates linked to their groups" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

        mine = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: group, signage_template: mine).save!
        _hidden = Model::Generator.signage_template(authority: authority).save!

        result = client.get(base, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [mine.id.to_s]
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
        hit = Model::Generator.signage_template(authority: authority)
        hit.name = "Lobby-welcome-#{Random::Secure.hex(3)}"
        hit.save!

        miss = Model::Generator.signage_template(authority: authority)
        miss.name = "cafeteria-#{Random::Secure.hex(3)}"
        miss.save!

        result = client.get("#{base}?q=lobby", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(hit.id.to_s)
        ids.should_not contain(miss.id.to_s)
      end

      it "excludes drafts from the index" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!

        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        # a layout patch on an approved template stages a draft row
        patch = client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        patch.status_code.should eq 200
        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 1

        result = client.get(base, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should eq [parent.id.to_s]
      end
    end

    describe "draft lifecycle" do
      it "edits an unapproved template in place (no draft created)" do
        parent = Model::Generator.signage_template.save!

        result = client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200
        JSON.parse(result.body)["id"].as_s.should eq parent.id.to_s

        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 0
        Model::SignageTemplate.find!(parent.id.as(UUID)).full_screen_takeover.should be_true
      end

      it "metadata-only changes apply to an approved template without a draft" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        result = client.patch(
          File.join(base, parent.id.to_s),
          body: {name: "new name", tags: ["lobby"]}.to_json,
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200

        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 0
        found = Model::SignageTemplate.find!(parent.id.as(UUID))
        found.name.should eq "new name"
        found.tags.should eq ["lobby"]
        found.approved.should be_true
      end

      it "stages layout changes on a draft when the template is approved" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        result = client.patch(
          File.join(base, parent.id.to_s),
          body: {layouts: [{position: "bottom", y_pos: 0.2}]}.to_json,
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200

        # the response is the draft, carrying the staged changes
        body = JSON.parse(result.body)
        body["id"].as_s.should_not eq parent.id.to_s
        body["live_template_id"].as_s.should eq parent.id.to_s
        body["layouts"].as_a.size.should eq 1

        # the approved version remains untouched
        found = Model::SignageTemplate.find!(parent.id.as(UUID))
        found.layouts.should be_empty

        # a second layout patch reuses the same draft
        again = client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        again.status_code.should eq 200
        JSON.parse(again.body)["id"].as_s.should eq body["id"].as_s
        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 1
      end

      it "syncs metadata changes onto an existing draft" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )

        result = client.patch(
          File.join(base, parent.id.to_s),
          body: {name: "synced name"}.to_json,
          headers: Spec::Authentication.headers,
        )
        result.status_code.should eq 200

        Model::SignageTemplate.find!(parent.id.as(UUID)).name.should eq "synced name"
        draft = Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).to_a.first
        draft.name.should eq "synced name"
      end

      it "show returns the draft by default and the parent with ?approved=true" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        draft = Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).to_a.first

        default = client.get(File.join(base, parent.id.to_s), headers: Spec::Authentication.headers)
        default.status_code.should eq 200
        JSON.parse(default.body)["id"].as_s.should eq draft.id.to_s

        approved = client.get("#{base}/#{parent.id}?approved=true", headers: Spec::Authentication.headers)
        approved.status_code.should eq 200
        JSON.parse(approved.body)["id"].as_s.should eq parent.id.to_s
      end

      it "404s when a draft is addressed by its own id" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        draft = Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).to_a.first

        result = client.get(File.join(base, draft.id.to_s), headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end

      it "approve promotes the draft onto the live template" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        client.patch(
          File.join(base, parent.id.to_s),
          body: {layouts: [{position: "top", y_pos: 0.3}], full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )

        result = client.post(File.join(base, parent.id.to_s, "approve"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["id"].as_s.should eq parent.id.to_s

        found = Model::SignageTemplate.find!(parent.id.as(UUID))
        found.layouts.size.should eq 1
        found.full_screen_takeover.should be_true
        found.approved.should be_true

        # the draft is consumed by the approval
        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 0
      end

      it "approve is 406 when there is nothing to approve" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        result = client.post(File.join(base, parent.id.to_s, "approve"), headers: Spec::Authentication.headers)
        result.status_code.should eq 406
      end

      it "discards the pending draft via DELETE /:id/draft" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!

        client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 1

        result = client.delete(File.join(base, parent.id.to_s, "draft"), headers: Spec::Authentication.headers)
        result.status_code.should eq 202
        Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).count.should eq 0
        Model::SignageTemplate.find?(parent.id.as(UUID)).should_not be_nil

        # nothing left to discard
        again = client.delete(File.join(base, parent.id.to_s, "draft"), headers: Spec::Authentication.headers)
        again.status_code.should eq 406
      end

      it "destroying the template removes drafts and group links" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        approver = Model::Generator.user(authority).save!
        group = Model::Generator.group(authority: authority).save!

        parent = Model::Generator.signage_template(authority: authority).save!
        parent.approver = approver
        parent.save!
        Model::Generator.group_signage_template(group: group, signage_template: parent).save!

        client.patch(
          File.join(base, parent.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        draft = Model::SignageTemplate.where(live_template_id: parent.id.as(UUID)).to_a.first

        result = client.delete(File.join(base, parent.id.to_s), headers: Spec::Authentication.headers)
        result.success?.should be_true

        Model::SignageTemplate.find?(parent.id.as(UUID)).should be_nil
        Model::SignageTemplate.find?(draft.id.as(UUID)).should be_nil
        Model::GroupSignageTemplate.find?({group.id.not_nil!, parent.id.not_nil!}).should be_nil
      end
    end

    describe "DELETE /:id?group_id= (unlink from a single group)" do
      it "admin unlinks the template from one group; the template and its other links remain" do
        _authority, template, _parent_a, group_a, group_b = setup_shared_template

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 202

        Model::SignageTemplate.find?(template.id.as(UUID)).should_not be_nil
        template_link?(group_a, template).should be_false
        template_link?(group_b, template).should be_true
      end

      it "a user with Delete on the group can unlink (without needing rights on other linked groups)" do
        _authority, template, _parent_a, group_a, group_b = setup_shared_template
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 202

        Model::SignageTemplate.find?(template.id.as(UUID)).should_not be_nil
        template_link?(group_a, template).should be_false
        template_link?(group_b, template).should be_true
      end

      it "Delete inherited from a parent group unlinks from the child group" do
        _authority, template, parent_a, group_a, group_b = setup_shared_template
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: parent_a, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 202

        Model::SignageTemplate.find?(template.id.as(UUID)).should_not be_nil
        template_link?(group_a, template).should be_false
        template_link?(group_b, template).should be_true
      end

      it "Manage on the group also permits unlinking" do
        _authority, template, _parent_a, group_a, _group_b = setup_shared_template
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Manage).save!

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 202
        template_link?(group_a, template).should be_false
      end

      it "is 403 without Delete or Manage on the group (link kept)" do
        _authority, template, _parent_a, group_a, _group_b = setup_shared_template
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        perms = Model::Permissions::Read | Model::Permissions::Update | Model::Permissions::Share
        Model::Generator.group_user(user: user, group: group_a, permissions: perms).save!

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 403
        template_link?(group_a, template).should be_true
      end

      it "is 403 when the user's Delete is on a different group than the one specified" do
        _authority, template, _parent_a, group_a, group_b = setup_shared_template
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_b, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: headers)
        result.status_code.should eq 403
        template_link?(group_a, template).should be_true
        template_link?(group_b, template).should be_true
      end

      it "is 404 when the template is not linked to the specified group" do
        authority, template, parent_a, group_a, group_b = setup_shared_template
        other = Model::Generator.group(authority: authority, parent: parent_a).save!

        result = client.delete("#{base}/#{template.id}?group_id=#{other.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404

        Model::SignageTemplate.find?(template.id.as(UUID)).should_not be_nil
        template_link?(group_a, template).should be_true
        template_link?(group_b, template).should be_true
      end

      it "is 404 for an unknown group or a group in another authority" do
        _authority, template, _parent_a, _group_a, _group_b = setup_shared_template

        result = client.delete("#{base}/#{template.id}?group_id=#{UUID.random}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404

        other_authority = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        foreign = Model::Generator.group(authority: other_authority).save!
        result = client.delete("#{base}/#{template.id}?group_id=#{foreign.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 404
        Model::SignageTemplate.find?(template.id.as(UUID)).should_not be_nil
      end

      it "unlinking leaves a pending draft intact" do
        authority, template, _parent_a, group_a, _group_b = setup_shared_template
        approver = Model::Generator.user(authority).save!
        template.approver = approver
        template.save!
        client.patch(
          File.join(base, template.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        draft = Model::SignageTemplate.where(live_template_id: template.id.as(UUID)).to_a.first

        result = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: Spec::Authentication.headers)
        result.status_code.should eq 202
        Model::SignageTemplate.find?(draft.id.as(UUID)).should_not be_nil
      end

      it "deletes the template (and its draft) outright when the last group link is removed" do
        authority, template, _parent_a, group_a, group_b = setup_shared_template
        approver = Model::Generator.user(authority).save!
        template.approver = approver
        template.save!
        client.patch(
          File.join(base, template.id.to_s),
          body: {full_screen_takeover: true}.to_json,
          headers: Spec::Authentication.headers,
        )
        draft = Model::SignageTemplate.where(live_template_id: template.id.as(UUID)).to_a.first

        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Delete).save!
        Model::Generator.group_user(user: user, group: group_b, permissions: Model::Permissions::Delete).save!

        first = client.delete("#{base}/#{template.id}?group_id=#{group_a.id}", headers: headers)
        first.status_code.should eq 202
        Model::SignageTemplate.find?(template.id.as(UUID)).should_not be_nil

        last = client.delete("#{base}/#{template.id}?group_id=#{group_b.id}", headers: headers)
        last.status_code.should eq 202
        Model::SignageTemplate.find?(template.id.as(UUID)).should be_nil
        Model::SignageTemplate.find?(draft.id.as(UUID)).should be_nil
        template_link?(group_b, template).should be_false
      end

      it "without group_id a user with Delete on a linked group still deletes the template outright" do
        _authority, template, _parent_a, group_a, group_b = setup_shared_template
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        Model::Generator.group_user(user: user, group: group_a, permissions: Model::Permissions::Delete).save!

        result = client.delete("#{base}/#{template.id}", headers: headers)
        result.status_code.should eq 202

        Model::SignageTemplate.find?(template.id.as(UUID)).should be_nil
        template_link?(group_a, template).should be_false
        template_link?(group_b, template).should be_false
      end
    end

    describe "POST /share" do
      it "admin shares templates into a signage group, skipping duplicates" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!

        a = Model::Generator.signage_template(authority: authority).save!
        b = Model::Generator.signage_template(authority: authority).save!

        # `b` is already linked — should be reported as already_present.
        Model::Generator.group_signage_template(group: target, signage_template: b).save!

        params = HTTP::Params.encode({"items" => "#{a.id},#{b.id}", "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.success?.should be_true

        body = JSON.parse(result.body)
        body["linked"].as_a.map(&.as_s).should eq [a.id.to_s]
        body["already_present"].as_a.map(&.as_s).should eq [b.id.to_s]

        target_id = target.id.as(UUID)
        Model::GroupSignageTemplate.find?({target_id, a.id.as(UUID)}).should_not be_nil
        Model::GroupSignageTemplate.find?({target_id, b.id.as(UUID)}).should_not be_nil
      end

      it "rejects when target group lacks the 'signage' subsystem" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        target = Model::Generator.group(authority: authority, subsystems: ["events"]).save!
        template = Model::Generator.signage_template(authority: authority).save!

        params = HTTP::Params.encode({"items" => template.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 403
      end

      it "404s when a template belongs to a different authority" do
        own = Model::Authority.find_by_domain("localhost").not_nil!
        other = Model::Generator.authority(domain: "http://other-#{Random::Secure.hex(3)}.example").save!
        target = Model::Generator.group(authority: own, subsystems: ["signage"]).save!

        local = Model::Generator.signage_template(authority: own).save!
        foreign = Model::Generator.signage_template(authority: other).save!

        params = HTTP::Params.encode({"items" => "#{local.id},#{foreign.id}", "to" => target.id.to_s})
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

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: source, signage_template: template).save!

        params = HTTP::Params.encode({"items" => template.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.success?.should be_true
        Model::GroupSignageTemplate.find?({target.id.as(UUID), template.id.as(UUID)}).should_not be_nil
      end

      it "rejects a user without Share or Manage on the target group" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Read).save!

        template = Model::Generator.signage_template(authority: authority).save!
        Model::Generator.group_signage_template(group: target, signage_template: template).save!

        params = HTTP::Params.encode({"items" => template.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.status_code.should eq 403
      end

      it "rejects a regular user trying to share a template they can't read" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        target = Model::Generator.group(authority: authority, subsystems: ["signage"]).save!
        Model::Generator.group_user(user: user, group: target, permissions: Model::Permissions::Share).save!

        # Admin-only template (no GroupSignageTemplate rows).
        admin_only = Model::Generator.signage_template(authority: authority).save!

        params = HTTP::Params.encode({"items" => admin_only.id.to_s, "to" => target.id.to_s})
        result = client.post("#{base}/share?#{params}", headers: headers)
        result.status_code.should eq 403
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

      describe "POST /:id/request_approval" do
        it "queues a PendingMail to the group's approvers and flags the unapproved version" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!
          zone = Model::Generator.zone.save!
          Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

          # unapproved template — the parent itself is the pending version
          template = Model::Generator.signage_template(authority: authority).save!
          Model::Generator.group_signage_template(group: group, signage_template: template).save!

          result = client.post(
            "#{base}/#{template.id}/request_approval?group_id=#{group.id}",
            body: {message: "please review"}.to_json,
            headers: headers,
          )
          result.success?.should be_true

          mail = Model::PendingMail.where(source_reference: "template-#{template.id}").to_a.first.not_nil!
          mail.send_to.should contain(approver.email.to_s)
          mail.template.should eq ["signage", "request_template_approval"]
          mail.source_service.should eq "signage"
          mail.zones.should contain(zone.id)
          mail.args["message"].should eq "please review"
          mail.args["group_id"].should eq group.id.to_s
          mail.args["template_id"].should eq template.id.to_s
          mail.expiry.should_not be_nil

          found = Model::SignageTemplate.find!(template.id.as(UUID))
          found.approval_requested.should be_true
          found.requested_by_id.should eq user.id

          zone.destroy
        end

        it "flags the draft when one is pending" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read | Model::Permissions::Update).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!

          template = Model::Generator.signage_template(authority: authority).save!
          template.approver = approver
          template.save!
          Model::Generator.group_signage_template(group: group, signage_template: template).save!

          # stage a draft
          client.patch(
            File.join(base, template.id.to_s),
            body: {full_screen_takeover: true}.to_json,
            headers: headers,
          )
          draft = Model::SignageTemplate.where(live_template_id: template.id.as(UUID)).to_a.first

          result = client.post(
            "#{base}/#{template.id}/request_approval?group_id=#{group.id}",
            body: {message: "draft ready"}.to_json,
            headers: headers,
          )
          result.success?.should be_true

          found = Model::SignageTemplate.find!(draft.id.as(UUID))
          found.approval_requested.should be_true
          found.requested_by_id.should eq user.id

          # the approved parent is not flagged
          Model::SignageTemplate.find!(template.id.as(UUID)).approval_requested.should be_false
        end

        it "returns 406 when the template has no unapproved changes" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!
          approver = Model::Generator.user(authority).save!
          Model::Generator.group_user(user: approver, group: group, permissions: Model::Permissions::Approve).save!

          template = Model::Generator.signage_template(authority: authority).save!
          template.approver = approver
          template.save!
          Model::Generator.group_signage_template(group: group, signage_template: template).save!

          result = client.post(
            "#{base}/#{template.id}/request_approval?group_id=#{group.id}",
            body: {message: "hi"}.to_json,
            headers: headers,
          )
          result.status_code.should eq 406
        end

        it "returns 406 when the group has no approvers up the tree" do
          authority = Model::Authority.find_by_domain("localhost").not_nil!
          user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

          group = Model::Generator.group(authority: authority).save!
          Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Read).save!

          template = Model::Generator.signage_template(authority: authority).save!

          result = client.post(
            "#{base}/#{template.id}/request_approval?group_id=#{group.id}",
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

          template = Model::Generator.signage_template(authority: authority).save!

          result = client.post(
            "#{base}/#{template.id}/request_approval?group_id=#{group.id}",
            body: {message: "hi"}.to_json,
            headers: headers,
          )
          result.status_code.should eq 403
        end
      end
    end
  end
end
