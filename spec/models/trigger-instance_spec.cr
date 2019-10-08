require "../helper"

module ACAEngine::Model
  describe TriggerInstance do
    it "saves a TriggerInstance" do
      inst = TriggerInstance.create!
      id = TriggerInstance.find!(inst.id).id
      id.should eq inst.id
    end

    it "sets importance before create" do
      trigger = Generator.trigger
      trigger.important = true

      trigger_instance = Generator.trigger_instance(trigger.save!)

      trigger_instance.important.should be_false
      trigger_instance.save!
      trigger_instance.important.should be_true

      trigger.destroy
      trigger_instance.destroy
    end

    describe "start/stop helpers" do
      it "stop" do
        inst = Generator.trigger_instance.save!
        inst.enabled.should be_true
        inst.stop

        inst.enabled.should be_false
        TriggerInstance.find!(inst.id).enabled.should be_false

        inst.destroy
      end

      it "start" do
        inst = Generator.trigger_instance
        inst.enabled = false
        inst.save!

        inst.enabled.should be_false
        inst.start
        inst.enabled.should be_true

        TriggerInstance.find!(inst.id).enabled.should be_true
        inst.destroy
      end
    end

    describe "index view" do
      it "#of finds TriggerInstance by parent Trigger" do
        trigger = Trigger.create!(name: "ree")
        inst = TriggerInstance.new
        inst.trigger = trigger
        inst.save!

        id = TriggerInstance.of(trigger.id).first?.try(&.id)
        id.should eq inst.id
      end

      it "#for finds TriggerInstance by parent ControlSystem" do
        cs = Generator.control_system.save!
        inst = TriggerInstance.new
        inst.control_system = cs
        inst.save!

        id = TriggerInstance.for(cs.id).first?.try(&.id)
        id.should eq inst.id
      end
    end
  end
end
