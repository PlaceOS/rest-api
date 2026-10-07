require "placeos-models/spec/generator"

module PlaceOS::Api::Spec::Tenancy
  # One customer organisation with a domain, three users and a small estate
  record Org,
    organisation : Model::Organisation,
    authority : Model::Authority,
    admin : Model::User,
    support : Model::User,
    user : Model::User,
    org_zone : Model::Zone,
    building : Model::Zone,
    system : Model::ControlSystem,
    mod : Model::Module

  # The shape of a shared cluster: PlaceOS staff on localhost (cluster reach),
  # NTT as a partner with its own staff organisation and one client (Acadian),
  # UCLA as a direct customer, and an unowned zone tree.
  record Fixture,
    management : Model::Partner,
    placeos : Org,
    ntt : Model::Partner,
    ntt_staff : Org,
    acadian : Org,
    ucla : Org,
    unowned_zone : Model::Zone,
    unowned_system : Model::ControlSystem

  def self.build : Fixture
    management = Model::Generator.partner(management: true).save!
    ntt = Model::Generator.partner.save!

    placeos = org("localhost", Model::Generator.organisation(partner: management, partner_staff: true).save!)
    ntt_staff = org("ntt.test", Model::Generator.organisation(partner: ntt, partner_staff: true).save!)
    acadian = org("acadian.test", Model::Generator.organisation(partner: ntt).save!)
    ucla = org("ucla.test", Model::Generator.organisation.save!)

    unowned_zone = Model::Generator.zone.tap { |z| z.name = "Unowned #{random_name}"; z.tags = Set{"org"} }.save!
    unowned_system = Model::Generator.control_system.tap do |sys|
      sys.name = "Unowned room #{random_name}"
      sys.zones = [unowned_zone.id.as(String)]
    end.save!

    Fixture.new(management, placeos, ntt, ntt_staff, acadian, ucla, unowned_zone, unowned_system)
  end

  def self.org(domain : String, organisation : Model::Organisation) : Org
    authority = Model::Authority.find_by_domain(domain) || Model::Generator.authority(domain)
    authority.domain = domain
    authority.organisation_id = organisation.id
    authority.save!

    org_zone = Model::Generator.zone.tap do |z|
      z.name = "ORG #{organisation.name}"
      z.tags = Set{"org"}
      z.organisation_id = organisation.id
    end.save!
    authority.config_will_change!
    authority.config["org_zone"] = JSON::Any.new(org_zone.id.as(String))
    authority.save!

    building = Model::Generator.zone.tap do |z|
      z.name = "Building #{organisation.name}"
      z.tags = Set{"building"}
      z.parent_id = org_zone.id
      z.organisation_id = organisation.id
    end.save!

    system = Model::Generator.control_system.tap do |sys|
      sys.name = "Room #{organisation.name}"
      sys.zones = [org_zone.id.as(String), building.id.as(String)]
      sys.organisation_id = organisation.id
    end.save!

    mod = Model::Generator.module(control_system: system).tap(&.organisation_id = organisation.id).save!
    system.modules = [mod.id.as(String)]
    system.save!

    Org.new(
      organisation: organisation,
      authority: authority,
      admin: Model::Generator.user(authority, admin: true).save!,
      support: Model::Generator.user(authority, support: true).save!,
      user: Model::Generator.user(authority).save!,
      org_zone: org_zone,
      building: building,
      system: system,
      mod: mod,
    )
  end

  # Removes everything a fixture and its example created. The suite only
  # clears tables once, so each example must leave the database as it found
  # it: other specs list zones and users without a page size.
  def self.teardown(f : Fixture)
    none = [] of ::PgORM::Value
    Model::Module.where("organisation_id IS NOT NULL", none).to_a.each { |row| row.destroy rescue nil }
    Model::ControlSystem.where("organisation_id IS NOT NULL", none).to_a.each { |row| row.destroy rescue nil }
    Model::Trigger.where("organisation_id IS NOT NULL OR name LIKE 'Template %'", none).to_a.each { |row| row.destroy rescue nil }
    Model::Edge.where("organisation_id IS NOT NULL", none).to_a.each { |row| row.destroy rescue nil }
    Model::Zone.where("organisation_id IS NOT NULL", none).to_a
      .sort_by { |zone| zone.parent_id.presence ? 0 : 1 }
      .each { |row| row.destroy rescue nil }
    [f.unowned_system, f.unowned_zone].each { |row| row.destroy rescue nil }

    Model::Grant.clear
    # fixture domains and anything an example created under them; localhost stays
    Model::Authority.where("domain LIKE '%.test'", none).to_a.each { |row| row.destroy rescue nil }
    [f.placeos.user, f.placeos.support, f.placeos.admin].each { |row| row.destroy rescue nil }
    localhost = Model::Authority.find?(f.placeos.authority.id.as(String))
    if localhost
      localhost.organisation_id = nil
      localhost.save!
    end
    Model::Organisation.clear
    Model::Partner.clear
  end

  # Bearer + Host headers for a user on their own domain
  def self.headers(user : Model::User) : HTTP::Headers
    authority = user.authority.as(Model::Authority)
    permissions = case {user.support, user.sys_admin}
                  when {true, true}  then Model::UserJWT::Permissions::AdminSupport
                  when {true, false} then Model::UserJWT::Permissions::Support
                  when {false, true} then Model::UserJWT::Permissions::Admin
                  else                    Model::UserJWT::Permissions::User
                  end
    jwt = Model::UserJWT.new(
      iss: Model::UserJWT::ISSUER,
      iat: 5.minutes.ago,
      exp: 1.hour.from_now,
      domain: authority.domain,
      id: user.id.as(String),
      user: Model::UserJWT::Metadata.new(name: user.name.as(String), email: user.email.to_s, permissions: permissions),
    )
    HTTP::Headers{
      "Authorization" => "Bearer #{jwt.encode}",
      "Content-Type"  => "application/json",
      "Host"          => authority.domain,
    }
  end

  def self.ids(body : String) : Array(String)
    Array(Hash(String, JSON::Any)).from_json(body).map(&.["id"].to_s)
  end
end
