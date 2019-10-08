require "../helper"

module ACAEngine::Model
  describe Module do
    describe "persistence" do
      Driver::Role.values.each do |role|
        spec_module_persistence(role)
      end
    end

    describe "merge_settings" do
      it "obeys logic module settings hierarchy" do
        driver = ACAEngine::Model::Generator.driver(role: Model::Driver::Role::Logic)
        driver.settings.not_nil!.push({Encryption::Level::None, %(value: 0\nscreen: 0\nfrangos: 0\nchop: 0)})
        driver.save!

        cs = ACAEngine::Model::Generator.control_system
        cs.settings.not_nil!.push({Encryption::Level::None, %(frangos: 1)})
        cs.save!

        zone = Generator.zone
        zone.settings.not_nil!.push({Encryption::Level::None, %(screen: 1)})
        zone.save!

        cs.zones = [zone.id.as(String)]
        cs.update!

        mod = ACAEngine::Model::Generator.module(driver: driver, control_system: cs)
        mod.settings.not_nil!.push({Encryption::Level::None, %(value: 2\n)})
        mod.save!

        merged_settings = JSON.parse(mod.merge_settings).as_h.transform_values { |v| v.as_i }

        # Module > Driver
        merged_settings["value"].should eq 2
        # Module > Zone > Driver
        merged_settings["screen"].should eq 1
        # Module > ControlSystem > Driver
        merged_settings["frangos"].should eq 1
        # Driver
        merged_settings["chop"].should eq 0

        {driver, zone, cs, mod}.each &.destroy
      end

      it "obeys driver-module settings hierarchy" do
        driver = ACAEngine::Model::Generator.driver(role: Model::Driver::Role::Service)
        driver.settings.not_nil!.push({Encryption::Level::None, %(value: 0\nscreen: 0\nfrangos: 0\nchop: 0)})
        driver.save!

        cs = ACAEngine::Model::Generator.control_system
        cs.settings.not_nil!.push({Encryption::Level::None, %(frangos: 1)})
        cs.save!

        zone = Generator.zone
        zone.settings.not_nil!.push({Encryption::Level::None, %(screen: 1)})
        zone.save!

        cs.zones = [zone.id.as(String)]
        cs.update!

        mod = ACAEngine::Model::Generator.module(driver: driver, control_system: cs)
        mod.settings.not_nil!.push({Encryption::Level::None, %(value: 2\n)})
        mod.save!

        merged_settings = JSON.parse(mod.merge_settings).as_h.transform_values { |v| v.as_i }

        # Module > Driver
        merged_settings["value"].should eq 2
        # Module > Driver
        merged_settings["screen"].should eq 0
        # Module > Driver
        merged_settings["frangos"].should eq 0
        # Driver
        merged_settings["chop"].should eq 0

        {driver, zone, cs, mod}.each &.destroy
      end
    end
  end
end

def spec_module_persistence(role)
  it "saves a #{role} module" do
    driver = ACAEngine::Model::Generator.driver(role: role)
    mod = ACAEngine::Model::Generator.module(driver: driver)
    begin
      mod.save!
      mod.persisted?.should be_true
    rescue e : RethinkORM::Error::DocumentInvalid
      inspect_error(e)
      raise e
    end
  end
end
