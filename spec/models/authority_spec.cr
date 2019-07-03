require "./helper"

module Engine::Model
  describe Authority do
    it "saves an Authority" do
      inst = Generator.authority.save!
      Authority.find!(inst.id).id.should eq inst.id
    end
  end
end
