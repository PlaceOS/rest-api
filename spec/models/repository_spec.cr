require "../helper"

module ACAEngine::Model
  describe Repository do
    it "saves a Repository" do
      repo = Generator.repository.save!
      Repository.find(repo.id).should_not be_nil
    end
  end
end
