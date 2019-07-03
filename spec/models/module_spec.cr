require "../helper"

module Engine::Model
  describe Module do
    describe "persistence" do
      Driver::Role.values.each do |role|
        spec_module_persistence(role)
      end
    end
  end
end

def spec_module_persistence(role)
  it "saves a #{role} module" do
    driver = Engine::Model::Generator.driver(role: role)
    mod = Engine::Model::Generator.module(driver: driver)
    begin
      mod.save!
      mod.persisted?.should be_true
    rescue e : RethinkORM::Error::DocumentInvalid
      inspect_error(e)
      raise e
    end
  end
end
