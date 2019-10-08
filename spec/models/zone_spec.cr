require "../helper"

module ACAEngine::Model
  # Transmogrified from the Ruby Engine spec
  describe Zone do
    it "saves a zone" do
      zone = Generator.zone

      begin
        zone.save!
      rescue e : RethinkORM::Error::DocumentInvalid
        inspect_error(e)
        raise e
      end

      zone.should_not be_nil
      id = zone.id
      id.should start_with "zone-" if id
      zone.persisted?.should be_true
    end

    it "should create triggers when added and removed from a zone" do
      # Set up
      zone = Generator.zone.save!
      cs = Generator.control_system

      id = zone.id
      cs.zones = [id] if id

      cs.save!

      trigger = Trigger.create!(name: "trigger test")

      # No trigger_instances associated with zone
      zone.trigger_instances.to_a.size.should eq 0
      cs.triggers.to_a.size.should eq 0

      id = trigger.id
      zone.triggers = [id] if id
      zone.triggers_changed?.should be_true
      zone.save

      cs.triggers.to_a.size.should eq 1
      cs.triggers.to_a[0].zone_id.should eq zone.id

      # Reload the relationships
      zone = Zone.find! zone.id

      zone.trigger_instances.to_a.size.should eq 1
      zone.triggers = [] of String
      zone.save

      zone = Zone.find! zone.id
      zone.trigger_instances.to_a.size.should eq 0

      {cs, zone, trigger}.each do |m|
        begin
          m.destroy
        rescue
        end
      end
    end
  end
end
