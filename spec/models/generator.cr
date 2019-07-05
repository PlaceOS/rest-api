require "faker"

require "../../src/models/*"
require "../../src/models/**"

RANDOM = Random.new

module Engine::Model
  # Defines generators for models
  module Generator
    def self.driver(role : Driver::Role? = nil, module_name : String? = nil, repo : Repository? = nil)
      role = self.role unless role
      repo = self.repository(type: Repository::Type::Driver).save! unless repo
      module_name = Faker::Hacker.noun unless module_name

      driver = Driver.new(
        name: RANDOM.base64(10),
        commit: RANDOM.hex(7),
        version: SemanticVersion.parse("1.1.1"),
        module_name: module_name,
      )

      driver.role = role
      driver.repository = repo
      driver
    end

    def self.role
      role_value = Driver::Role.names.sample(1).first
      Driver::Role.parse(role_value)
    end

    def self.repository_type
      type = Repository::Type.names.sample(1).first
      Repository::Type.parse(type)
    end

    def self.repository(type : Repository::Type? = nil)
      type = self.repository_type unless type
      Repository.new(
        name: Faker::Hacker.noun,
        type: type,
        folder_name: Faker::Hacker.noun,
        description: Faker::Hacker.noun,
        uri: Faker::Internet.url,
        commit_hash: "head",
      )
    end

    def self.trigger(system : ControlSystem? = nil)
      trigger = Trigger.new(
        name: Faker::Hacker.noun,
      )
      trigger.control_system = system if system
      trigger
    end

    def self.trigger_instance(trigger = nil, zone = nil, control_system = nil)
      trigger = self.trigger.save! unless trigger
      instance = TriggerInstance.new(important: false)
      instance.trigger = trigger

      instance.zone = zone if zone
      instance.control_system = control_system if control_system

      instance
    end

    def self.control_system
      ControlSystem.new(
        name: RANDOM.base64(10),
      )
    end

    def self.module(driver = nil, control_system = nil)
      mod_name = Faker::Hacker.noun

      driver = Generator.driver(module_name: mod_name) if driver.nil?
      driver.save! unless driver.persisted?

      mod = case driver.role
            when Driver::Role::Logic
              Module.new(custom_name: mod_name, uri: Faker::Internet.url)
            when Driver::Role::Device
              Module.new(
                custom_name: mod_name,
                uri: Faker::Internet.url,
                ip: Faker::Internet.ip_v4_address,
                port: rand((1..6555)),
              )
            when Driver::Role::SSH
              Module.new(
                custom_name: mod_name,
                uri: Faker::Internet.url,
                ip: Faker::Internet.ip_v4_address,
                port: rand((1..65_535)),
              )
            else
              # Driver::Role::Service
              Module.new(custom_name: mod_name, uri: Faker::Internet.url)
            end

      # Set driver
      mod.driver = driver

      # Set cs
      mod.control_system = !control_system ? Generator.control_system.save! : control_system

      mod
    end

    def self.zone
      Zone.new(
        name: RANDOM.base64(10),
      )
    end

    def self.authority
      Authority.new(
        name: Faker::Hacker.noun,
        domain: Faker::Internet.url,
      )
    end

    def self.user(authority : Authority? = nil)
      authority = self.authority.save! unless authority
      User.new(
        name: Faker::Name.name,
        email: Faker::Internet.email,
        authority_id: authority.id,
      )
    end

    def self.authenticated_user(authority = nil)
      user = self.user(authority)
      user.support = true
      user.sys_admin = true
      user
    end

    def self.adfs_strat(authority : Authority? = nil)
      authority = self.authority.save! unless authority
      AdfsStrat.new(
        name: Faker::Name.name,
        authority_id: authority.id,
        assertion_consumer_service_url: Faker::Internet.url,
        idp_sso_target_url: Faker::Internet.url,
      )
    end

    def self.oauth_strat(authority : Authority? = nil)
      authority = self.authority.save! unless authority
      OauthStrat.new(
        name: Faker::Name.name,
        authority_id: authority.id,
      )
    end

    def self.ldap_strat(authority : Authority? = nil)
      authority = self.authority.save! unless authority
      LdapStrat.new(
        name: Faker::Name.name,
        authority_id: authority.id,
        host: Faker::Internet.domain_name,
        port: rand(1..65535),
        base: "/",
      )
    end

    def self.bool
      [true, false].sample(1).first
    end

    def self.jwt(user : User? = nil)
      user = self.user.save! if user.nil?
      UserJWT.new(
        id: user.id,
        email: user.email,
        support: user.support,
        admin: user.sys_admin,
      )
    end

    def self.user_jwt(id : String? = nil, email : String? = nil, support : Bool? = nil, admin : Bool? = nil)
      UserJWT.new(
        id: id || RANDOM.base64(10),
        email: email || Faker::Internet.email,
        support: support || self.bool,
        admin: admin || self.bool,
      )
    end
  end
end
