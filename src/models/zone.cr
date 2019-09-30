require "rethinkdb-orm"
require "time"

require "./base/model"
require "./settings"

module Engine::Model
  class Zone < ModelBase
    include RethinkORM::Timestamps
    include Settings
    table :zone

    attribute name : String, es_type: "keyword"
    attribute description : String
    attribute tags : String

    attribute triggers : Array(String) = [] of String

    has_many TriggerInstance, collection_name: "trigger_instances", dependent: :destroy

    # Looks up the triggers attached to the zone
    def trigger_data : Array(Trigger)
      triggers = @triggers
      if !triggers || triggers.empty?
        [] of Trigger
      else
        Trigger.find_all(triggers).to_a
      end
    end

    validates :name, presence: true
    ensure_unique :name

    def systems
      ControlSystem.by_zone_id(self.id)
    end

    before_destroy :remove_zone

    # Removes self from ControlSystems
    protected def remove_zone
      self.systems.try &.each do |cs|
        zones = cs.zones
        if zones
          cs.zones = zones.reject(self.id)

          version = cs.version
          cs.version = version + 1 if version

          cs.save!
        end
      end
    end

    # =======================
    # Settings
    # =======================

    # Array of encrypted YAML setting and the encryption privilege
    attribute settings : Array(Setting) = [] of Setting, es_keyword: "text"

    # Settings encryption
    before_save do
      # Encrypt all settings
      @settings = encrypt_settings(@settings.as(Array(Setting)))
    end

    # =======================
    # Zone Trigger Management
    # =======================

    @remove_triggers : Array(String) = [] of String
    @add_triggers : Array(String) = [] of String

    @update_systems = false

    before_save :check_triggers

    protected def check_triggers
      if self.triggers_changed?
        previous = self.triggers_was || [] of String
        current = self.triggers || [] of String

        @remove_triggers = previous - current
        @add_triggers = current - previous

        @update_systems = !@remove_triggers.empty? || !@add_triggers.empty?
      else
        @update_systems = false
      end
    end

    after_save :update_triggers

    protected def update_triggers
      return unless @update_systems

      # Remove TriggerInstances
      unless @remove_triggers.empty?
        self.trigger_instances.each do |trig|
          trig.destroy if @remove_triggers.includes?(trig.trigger_id)
        end
      end

      # Add TriggerInstances
      unless @add_triggers.empty?
        self.systems.try &.each do |sys|
          @add_triggers.each do |trig_id|
            inst = TriggerInstance.new(trigger_id: trig_id, zone_id: self.id)
            inst.control_system = sys
            inst.save
          end
        end
      end
    end
  end
end
