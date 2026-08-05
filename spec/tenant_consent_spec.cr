require "./helper"

module PlaceOS::Api
  describe TenantConsent do
    describe ".upsert_calendar_tenant" do
      app = {client_id: UUID.v4.to_s, client_secret: "sup3r-s3cret"}
      azure_tenant = UUID.v4.to_s

      it "creates a staff-api tenant holding the app-only credential when the domain has none" do
        domain = "consent-create-#{Random::Secure.hex(4)}.example.com"
        begin
          tenant = TenantConsent.upsert_calendar_tenant(domain, azure_tenant, app, "Test Org")

          tenant.persisted?.should be_true
          tenant.name.should eq "Test Org"
          tenant.platform.should eq "office365"
          tenant.delegated.should be_false

          stored = ::PlaceOS::Model::Tenant.find_by?(domain: domain).not_nil!
          # encrypted at rest, and decrypts back to exactly the credential written
          stored.credentials.starts_with?('\e').should be_true
          creds = JSON.parse(PlaceOS::Encryption.decrypt(string: stored.credentials, id: domain, level: :never_display))
          creds["tenant"].as_s.should eq azure_tenant
          creds["client_id"].as_s.should eq app[:client_id]
          creds["client_secret"].as_s.should eq app[:client_secret]

          # the app-only calendar client builds from the stored credential
          stored.place_calendar_client.should be_a(PlaceCalendar::Client)
        ensure
          ::PlaceOS::Model::Tenant.find_by?(domain: domain).try &.destroy
        end
      end

      # the flow can be driven from Backoffice on any host, so it must key off
      # the authority being integrated, never the host in the request
      it "writes to the authority's own domain, leaving another domain's tenant alone" do
        authority_domain = "consent-authority-#{Random::Secure.hex(4)}.example.com"
        other_domain = "consent-bystander-#{Random::Secure.hex(4)}.example.com"
        begin
          bystander = ::PlaceOS::Model::Tenant.create!(
            name: "Bystander", domain: other_domain, platform: "office365",
            delegated: true, credentials: {conference_type: "teamsForBusiness"}.to_json,
          )
          before = ::PlaceOS::Model::Tenant.find!(bystander.id).credentials

          TenantConsent.upsert_calendar_tenant(authority_domain, azure_tenant, app, "Authority Org")

          ::PlaceOS::Model::Tenant.find_by?(domain: authority_domain).should_not be_nil
          untouched = ::PlaceOS::Model::Tenant.find!(bystander.id)
          untouched.delegated.should be_true
          untouched.credentials.should eq before
        ensure
          ::PlaceOS::Model::Tenant.find_by?(domain: authority_domain).try &.destroy
          ::PlaceOS::Model::Tenant.find_by?(domain: other_domain).try &.destroy
        end
      end

      it "switches an existing delegated tenant onto the app-only credential" do
        domain = "consent-update-#{Random::Secure.hex(4)}.example.com"
        begin
          existing = ::PlaceOS::Model::Tenant.create!(
            name: "Existing", domain: domain, platform: "office365",
            delegated: true, credentials: {conference_type: "teamsForBusiness"}.to_json,
          )

          tenant = TenantConsent.upsert_calendar_tenant(domain, azure_tenant, app, "ignored - tenant exists")

          # same row updated, not a duplicate
          tenant.id.should eq existing.id
          ::PlaceOS::Model::Tenant.where(domain: domain).count.should eq 1

          stored = ::PlaceOS::Model::Tenant.find_by?(domain: domain).not_nil!
          stored.name.should eq "Existing"
          stored.delegated.should be_false
          creds = JSON.parse(PlaceOS::Encryption.decrypt(string: stored.credentials, id: domain, level: :never_display))
          creds["client_id"].as_s.should eq app[:client_id]
          stored.place_calendar_client.should be_a(PlaceCalendar::Client)
        ensure
          ::PlaceOS::Model::Tenant.find_by?(domain: domain).try &.destroy
        end
      end
    end
  end
end
