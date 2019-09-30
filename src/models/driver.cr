require "semantic_version"

require "./base/model"
require "./settings"

module Engine::Model
  class Driver < ModelBase
    include RethinkORM::Timestamps
    include Settings

    table :driver

    after_save :update_modules
    before_destroy :cleanup_modules

    enum Role
      SSH
      Device
      Service
      Logic
    end

    attribute name : String, es_type: "keyword"
    attribute description : String

    attribute default_uri : String
    attribute default_port : Int32

    enum_attribute role : Role, es_type: "integer"

    # Driver version management
    attribute file_name : String
    attribute commit : String
    attribute version : SemanticVersion, converter: SemanticVersion::Converter
    belongs_to Repository

    # Module instance configuration
    attribute module_name : String
    attribute settings : Array(Setting) = [] of Setting, es_keyword: "text"

    # Don't include this module in statistics or disconnected searches
    # Might be a device that commonly goes offline (like a PC or Display that only supports Wake on Lan)
    attribute ignore_connected : Bool = false

    # Find the modules that rely on this driver
    def modules
      Module.by_driver_id(self.id)
    end

    def default_port=(port)
      self.role = Role::Device
      self.default_port = port
    end

    def default_uri=(uri)
      self.role = Role::Service
      self.default_uri = uri
    end

    # Validations
    validates :name, presence: true
    validates :role, presence: true
    validates :commit, presence: true
    validates :version, presence: true
    validates :module_name, presence: true

    # Validate the repository type
    #
    validate ->(this : Driver) {
      return unless (repo = this.repository)
      this.validation_error(:repository, "should be a driver repository") unless repo.type == Repository::Type::Driver
    }

    # Delete all the module references relying on this driver
    #
    protected def cleanup_modules
      self.modules.each &.destroy
    end

    # Reload all modules to update their settings
    #
    protected def update_modules
      self.modules.each do |mod|
        mod.driver = self
        mod.save
      end
    end
  end
end
