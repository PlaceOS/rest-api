require "digest/md5"

require "../helper"

module Engine::Model
  describe User do
    it "saves a User" do
      user = Generator.user.save!
      User.find!(user.id).id.should eq user.id
    end

    it "sets email digest on save" do
      user = Generator.user
      expected_digest = Digest::MD5.hexdigest(user.email.not_nil!)

      user.email_digest.should be_nil
      user.save!

      user.persisted?.should be_true
      user.email_digest.should eq expected_digest
    end

    it "serialises public visible attributes" do
      user = Generator.user.save!

      public_user = JSON.parse(user.as_public_json).as_h

      public_attributes = User::PUBLIC_DATA.to_a.map do |field|
        field.is_a?(NamedTuple) ? field[:field].to_s : field.to_s
      end

      public_user.keys.sort.should eq public_attributes.sort
    end

    it "serialises admin visible attributes" do
      user = Generator.user.save!
      admin_user = JSON.parse(user.as_admin_json).as_h

      admin_attributes = User::ADMIN_DATA.to_a.map do |field|
        field.is_a?(NamedTuple) ? field[:field].to_s : field.to_s
      end

      admin_user.keys.sort.should eq admin_attributes.sort
    end
  end
end
