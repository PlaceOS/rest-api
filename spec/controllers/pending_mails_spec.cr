require "../helper"

# Build + persist a pending mail, applying any attribute overrides.
def create_pending_mail(
  authority : PlaceOS::Model::Authority? = nil,
  user : PlaceOS::Model::User? = nil,
  source_service : String? = nil,
  source_reference : String? = nil,
  zones : Array(String) = [] of String,
  sent_at : Time? = nil,
  rejected_at : Time? = nil,
  expiry : Time? = nil,
  send_at : Time? = nil,
) : PlaceOS::Model::PendingMail
  mail = PlaceOS::Model::Generator.pending_mail(authority: authority, user: user)
  mail.source_service = source_service
  mail.source_reference = source_reference
  mail.zones = zones
  mail.sent_at = sent_at
  mail.rejected_at = rejected_at
  mail.expiry = expiry
  mail.send_at = send_at
  mail.save!
  mail
end

# A fresh authority with a unique domain (avoids the unique-domain constraint).
def other_authority : PlaceOS::Model::Authority
  PlaceOS::Model::Generator.authority(domain: "http://other-#{random_name}.test").save!
end

# GET the index with the supplied params, retrying until `block` holds
# (Elasticsearch indexing is asynchronous).
def pending_mail_index_ids(params : Hash(String, String), headers : HTTP::Headers, &block : Array(String) -> Bool) : Bool
  path = "#{PlaceOS::Api::PendingMails.base_route.rstrip('/')}?#{HTTP::Params.encode(params)}"
  until_expected("GET", path, headers) do |response|
    next false unless response.success?
    ids = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
    block.call(ids)
  end
end

module PlaceOS::Api
  describe PendingMails do
    Spec.test_404(PendingMails.base_route, model_name: Model::PendingMail.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      it "filters by source_service" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        match = create_pending_mail(source_service: svc)
        other = create_pending_mail(source_service: "svc-#{random_name}")

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc}, headers) do |ids|
          ids.includes?(match.id.to_s) && !ids.includes?(other.id.to_s)
        end.should be_true

        match.destroy
        other.destroy
      end

      it "filters by source_reference" do
        headers = Spec::Authentication.headers
        ref = "ref-#{random_name}"
        match = create_pending_mail(source_reference: ref)
        other = create_pending_mail(source_reference: "ref-#{random_name}")

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_reference" => ref}, headers) do |ids|
          ids.includes?(match.id.to_s) && !ids.includes?(other.id.to_s)
        end.should be_true

        match.destroy
        other.destroy
      end

      it "filters by user_id" do
        headers = Spec::Authentication.headers
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        svc = "svc-#{random_name}"
        user = Model::Generator.user(authority).save!
        match = create_pending_mail(source_service: svc, user: user)
        other = create_pending_mail(source_service: svc)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc, "user_id" => user.id.to_s}, headers) do |ids|
          ids.includes?(match.id.to_s) && !ids.includes?(other.id.to_s)
        end.should be_true

        match.destroy
        other.destroy
        user.destroy
      end

      it "filters by zones" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        zone = "zone-#{random_name}"
        match = create_pending_mail(source_service: svc, zones: [zone])
        other = create_pending_mail(source_service: svc, zones: ["zone-#{random_name}"])

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc, "zones" => zone}, headers) do |ids|
          ids.includes?(match.id.to_s) && !ids.includes?(other.id.to_s)
        end.should be_true

        match.destroy
        other.destroy
      end

      it "excludes rejected mail by default and includes it on request" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        pending = create_pending_mail(source_service: svc)
        rejected = create_pending_mail(source_service: svc, rejected_at: Time.utc)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc}, headers) do |ids|
          ids.includes?(pending.id.to_s) && !ids.includes?(rejected.id.to_s)
        end.should be_true

        pending_mail_index_ids({"source_service" => svc, "include_rejected" => "true"}, headers) do |ids|
          ids.includes?(pending.id.to_s) && ids.includes?(rejected.id.to_s)
        end.should be_true

        pending.destroy
        rejected.destroy
      end

      it "unsent_only returns mail that is neither sent nor rejected" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        pending = create_pending_mail(source_service: svc)
        sent = create_pending_mail(source_service: svc, sent_at: Time.utc)
        rejected = create_pending_mail(source_service: svc, rejected_at: Time.utc)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc, "unsent_only" => "true"}, headers) do |ids|
          ids.includes?(pending.id.to_s) && !ids.includes?(sent.id.to_s) && !ids.includes?(rejected.id.to_s)
        end.should be_true

        pending.destroy
        sent.destroy
        rejected.destroy
      end

      it "excludes expired mail by default, keeping future and no-expiry mail" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        no_expiry = create_pending_mail(source_service: svc)
        future = create_pending_mail(source_service: svc, expiry: Time.utc + 1.hour)
        expired = create_pending_mail(source_service: svc, expiry: Time.utc - 1.hour)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc}, headers) do |ids|
          ids.includes?(no_expiry.id.to_s) && ids.includes?(future.id.to_s) && !ids.includes?(expired.id.to_s)
        end.should be_true

        pending_mail_index_ids({"source_service" => svc, "include_expired" => "true"}, headers) do |ids|
          ids.includes?(no_expiry.id.to_s) && ids.includes?(future.id.to_s) && ids.includes?(expired.id.to_s)
        end.should be_true

        no_expiry.destroy
        future.destroy
        expired.destroy
      end

      it "filters by sent_after" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        old_mail = create_pending_mail(source_service: svc, sent_at: Time.utc - 10.days)
        recent = create_pending_mail(source_service: svc, sent_at: Time.utc - 1.hour)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        cutoff = (Time.utc - 1.day).to_rfc3339
        pending_mail_index_ids({"source_service" => svc, "sent_after" => cutoff}, headers) do |ids|
          ids.includes?(recent.id.to_s) && !ids.includes?(old_mail.id.to_s)
        end.should be_true

        old_mail.destroy
        recent.destroy
      end

      it "sent window also matches rejected time when include_rejected is set" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        recently_rejected = create_pending_mail(source_service: svc, rejected_at: Time.utc - 1.hour)
        old_rejected = create_pending_mail(source_service: svc, rejected_at: Time.utc - 10.days)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        cutoff = (Time.utc - 1.day).to_rfc3339
        pending_mail_index_ids({"source_service" => svc, "sent_after" => cutoff, "include_rejected" => "true"}, headers) do |ids|
          ids.includes?(recently_rejected.id.to_s) && !ids.includes?(old_rejected.id.to_s)
        end.should be_true

        recently_rejected.destroy
        old_rejected.destroy
      end

      it "filters by send_at_after" do
        headers = Spec::Authentication.headers
        svc = "svc-#{random_name}"
        soon = create_pending_mail(source_service: svc, send_at: Time.utc + 1.hour)
        later = create_pending_mail(source_service: svc, send_at: Time.utc + 10.days)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        cutoff = (Time.utc + 1.day).to_rfc3339
        pending_mail_index_ids({"source_service" => svc, "send_at_after" => cutoff}, headers) do |ids|
          ids.includes?(later.id.to_s) && !ids.includes?(soon.id.to_s)
        end.should be_true

        soon.destroy
        later.destroy
      end

      it "filters by group_id (zones anchored to the group)" do
        clear_group_tables
        headers = Spec::Authentication.headers
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        svc = "svc-#{random_name}"
        zone = Model::Generator.zone.save!
        group = Model::Generator.group(authority: authority).save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Read).save!

        match = create_pending_mail(source_service: svc, zones: [zone.id.as(String)])
        other = create_pending_mail(source_service: svc, zones: ["zone-#{random_name}"])

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc, "group_id" => group.id.to_s}, headers) do |ids|
          ids.includes?(match.id.to_s) && !ids.includes?(other.id.to_s)
        end.should be_true

        match.destroy
        other.destroy
        zone.destroy
      end

      it "regular users only see their own authority and may not target another" do
        local_auth = Model::Authority.find_by_domain("localhost").not_nil!
        other_auth = other_authority

        svc = "svc-#{random_name}"
        _, scoped_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        mine = create_pending_mail(authority: local_auth, source_service: svc)
        theirs = create_pending_mail(authority: other_auth, source_service: svc)

        sleep 1.second
        refresh_elastic(Model::PendingMail.table_name)

        pending_mail_index_ids({"source_service" => svc}, scoped_headers) do |ids|
          ids.includes?(mine.id.to_s) && !ids.includes?(theirs.id.to_s)
        end.should be_true

        # explicitly targeting another authority is forbidden for non-support
        path = "#{PendingMails.base_route.rstrip('/')}?#{HTTP::Params.encode({"authority_id" => other_auth.id.to_s})}"
        client.get(path, headers: scoped_headers).status_code.should eq 403

        mine.destroy
        theirs.destroy
        other_auth.destroy
      end
    end

    describe "show" do
      it "returns the mail" do
        mail = create_pending_mail
        result = client.get("#{PendingMails.base_route}#{mail.id}", headers: Spec::Authentication.headers)
        result.success?.should be_true
        Model::PendingMail.from_trusted_json(result.body).id.should eq mail.id
        mail.destroy
      end

      it "forbids a non-support user from viewing another authority's mail" do
        auth = other_authority
        mail = create_pending_mail(authority: auth)
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        result = client.get("#{PendingMails.base_route}#{mail.id}", headers: headers)
        result.status_code.should eq 403

        mail.destroy
        auth.destroy
      end
    end

    describe "destroy" do
      it "removes the mail" do
        mail = create_pending_mail
        result = client.delete("#{PendingMails.base_route}#{mail.id}", headers: Spec::Authentication.headers)
        result.success?.should be_true
        Model::PendingMail.find?(mail.id.as(UUID)).should be_nil
      end
    end

    describe "reject" do
      it "marks the mail rejected" do
        mail = create_pending_mail
        result = client.post("#{PendingMails.base_route}#{mail.id}/reject?#{HTTP::Params.encode({"rejected_reason" => "opted out"})}", headers: Spec::Authentication.headers)
        result.success?.should be_true

        mail.reload!
        mail.rejected_at.should_not be_nil
        mail.rejected_reason.should eq "opted out"
        mail.destroy
      end
    end

    describe "sent" do
      it "marks the mail sent" do
        mail = create_pending_mail
        result = client.post("#{PendingMails.base_route}#{mail.id}/sent?#{HTTP::Params.encode({"sent_by" => "mailer"})}", headers: Spec::Authentication.headers)
        result.success?.should be_true

        mail.reload!
        mail.sent_at.should_not be_nil
        mail.sent_by.should eq "mailer"
        mail.destroy
      end
    end

    describe "cleanup" do
      it "deletes sent, rejected and expired mail, keeping pending mail" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        pending = create_pending_mail(authority: authority)
        sent = create_pending_mail(authority: authority, sent_at: Time.utc)
        rejected = create_pending_mail(authority: authority, rejected_at: Time.utc)
        expired = create_pending_mail(authority: authority, expiry: Time.utc - 1.hour)

        result = client.delete("#{PendingMails.base_route}cleanup", headers: Spec::Authentication.headers)
        result.success?.should be_true

        Model::PendingMail.find?(sent.id.as(UUID)).should be_nil
        Model::PendingMail.find?(rejected.id.as(UUID)).should be_nil
        Model::PendingMail.find?(expired.id.as(UUID)).should be_nil
        Model::PendingMail.find?(pending.id.as(UUID)).should_not be_nil

        pending.destroy
      end
    end

    describe "subsystem-based permissions" do
      ::Spec.before_each { clear_group_tables }

      it "allows a support-subsystem user with Delete reach on a mail's zone to destroy it" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Delete).save!

        mail = create_pending_mail(authority: authority, zones: [zone.id.as(String)])

        result = client.delete("#{PendingMails.base_route}#{mail.id}", headers: headers)
        result.success?.should be_true
        Model::PendingMail.find?(mail.id.as(UUID)).should be_nil

        zone.destroy
      end

      it "rejects destroy when the support-subsystem user has no reach on the mail's zones" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Manage).save!
        # No GroupZone reach to the mail's zone.

        zone = Model::Generator.zone.save!
        mail = create_pending_mail(authority: authority, zones: [zone.id.as(String)])

        result = client.delete("#{PendingMails.base_route}#{mail.id}", headers: headers)
        result.status_code.should eq 403

        mail.destroy
        zone.destroy
      end

      it "Delete reach permits destroy but not reject (which needs Update)" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Delete).save!
        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Delete).save!

        mail = create_pending_mail(authority: authority, zones: [zone.id.as(String)])

        client.post("#{PendingMails.base_route}#{mail.id}/reject", headers: headers).status_code.should eq 403

        mail.destroy
        zone.destroy
      end

      it "Update reach permits reject" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        group = Model::Generator.group(authority: authority, subsystems: ["support"]).save!
        Model::Generator.group_user(user: user, group: group, permissions: Model::Permissions::Update).save!
        zone = Model::Generator.zone.save!
        Model::Generator.group_zone(group: group, zone: zone, permissions: Model::Permissions::Update).save!

        mail = create_pending_mail(authority: authority, zones: [zone.id.as(String)])

        result = client.post("#{PendingMails.base_route}#{mail.id}/reject", headers: headers)
        result.success?.should be_true
        mail.reload!
        mail.rejected_at.should_not be_nil

        mail.destroy
        zone.destroy
      end

      it "forbids cleanup for a non-support user" do
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        result = client.delete("#{PendingMails.base_route}cleanup", headers: headers)
        result.status_code.should eq 403
      end
    end
  end
end
