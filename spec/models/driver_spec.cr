require "./helper"

module Engine::Model
  describe Driver do
    it "creates a driver" do
      driver = Generator.driver(role: Driver::Role::Service)
      driver.version = SemanticVersion.parse("1.1.1")
      driver.save!

      driver.persisted?.should be_true

      driver.id.try &.should start_with "driver-"
      driver.role.should eq Driver::Role::Service
      driver.version.should eq SemanticVersion.parse("1.1.1")
    end

    it "finds modules by driver" do
      mod = Generator.module.save!
      driver = mod.driver.not_nil!

      driver.persisted?.should be_true
      mod.persisted?.should be_true

      Module.by_driver_id(driver.id).first.id.should eq mod.id
    end

    describe "callbacks" do
      it "#cleanup_modules removes driver modules" do
        mod = Generator.module.save!
        driver = mod.driver.not_nil!

        driver.persisted?.should be_true
        mod.persisted?.should be_true

        Module.by_driver_id(driver.id).first.id.should eq mod.id
        driver.destroy
        Module.find(mod.id).should be_nil
      end

      it "#update_modules updates dependent modules' driver metadata" do
        driver = Generator.driver(role: Driver::Role::Device).save!
        mod = Generator.module(driver: driver).save!

        driver.persisted?.should be_true
        mod.persisted?.should be_true

        driver.role = Driver::Role::SSH
        driver.save!
        driver.persisted?.should be_true

        Module.find!(mod.id).role.should eq Driver::Role::SSH
      end
    end
  end
end
