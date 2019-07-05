require "random"
require "rethinkdb-orm"
require "time"

require "./base/model"

module Engine::Model
  class TriggerInstance < ModelBase
    include RethinkORM::Timestamps
    table :trig

    belongs_to ControlSystem
    belongs_to Trigger
    belongs_to Zone

    attribute enabled : Bool = true
    attribute triggered : Bool = false
    attribute important : Bool = false

    attribute webhook_secret : String = ->{ Random::Secure.hex(32) }
    attribute trigger_count : Int32 = 0

    before_create :set_importance

    # Increment the trigger_count of a TriggerInstance in place
    #
    def self.increment_trigger_count(id : String)
      TriggerInstance.table_query do |q|
        q.get(id).update do |doc|
          doc.merge({"trigger_count" => doc["trigger_count"].add(1)})
        end
      end
    end

    # ----------------
    # PARENT ACCESSORS
    # ----------------

    def name
      self.trigger.try(&.name)
    end

    def description
      self.trigger.try(&.description)
    end

    def conditions
      self.trigger.try(&.conditions)
    end

    def actions
      self.trigger.try(&.actions)
    end

    def debounce_period
      self.trigger.try(&.debounce_period)
    end

    def binding
      self.id
    end

    # ------------
    # VIEWS ACCESS
    # ------------

    # Look up TriggerInstances by ControlSystem
    def self.for(control_system_id)
      TriggerInstance.by_control_system_id(control_system_id)
    end

    # Look up TriggerInstances belonging to Trigger
    def self.of(trigger_id)
      TriggerInstance.by_trigger_id(trigger_id)
    end

    # Override to_json, set method fields
    def as_json
      self.attributes.merge({
        :name        => name,
        :description => description,
        :conditions  => conditions,
        :actions     => actions,
        :binding     => binding,
      }).to_json
    end

    # --------------------
    # START / STOP HELPERS
    # --------------------

    protected def set_importance
      self.important = self.trigger.try &.important || self.important
    end

    # Enables the trigger
    def start
      self.update_fields(enabled: true)
    end

    # Disables the trigger
    def stop
      self.update_fields(enabled: false)
    end

    # -----------
    # VALIDATIONS
    # -----------

    # Ensure the models exist in the database
    validates :control_system, presence: true
    validates :trigger, presence: true
  end
end
