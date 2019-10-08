require "uuid"

require "./helper"
require "../src/encryption"

module ACAEngine
  describe Encryption do
    describe Encryption::Level::None do
      it "preserves plaintext" do
        plaintext = Faker::Internet.password(10, 20)
        id = UUID.random.to_s
        Encryption.encrypt(string: plaintext, id: id, level: Encryption::Level::None).should eq plaintext
      end
    end

    Encryption::Level.values.reject(Encryption::Level::None).each do |level|
      describe level do
        it "encrypts/decrypts" do
          plaintext = Faker::Internet.password(10, 20)
          id = UUID.random.to_s

          encrypted = Encryption.encrypt(string: plaintext, id: id, level: level)
          Encryption.decrypt(string: encrypted, id: id, level: level).should eq plaintext
        end

        it "exclusively decrypts #{level} encrypted cipher text" do
          plaintext = Faker::Internet.password(10, 20)
          id = UUID.random.to_s
          encrypted = Encryption.encrypt(string: plaintext, id: id, level: level)

          Encryption::Level.values.each do |level_attempt|
            if level_attempt == level
              Encryption.decrypt(string: encrypted, id: id, level: level_attempt).should eq plaintext
            else
              Encryption.decrypt(string: encrypted, id: id, level: level_attempt).should_not eq plaintext
            end
          end

          decrypted = Encryption.decrypt(string: encrypted, id: id, level: level)
          decrypted.should eq plaintext
        end

        describe "idempotent" do
          it "#decrypt" do
            plaintext = Faker::Internet.password(10, 20)
            id = UUID.random.to_s
            encrypted = Encryption.encrypt(string: plaintext, id: id, level: level)

            decrypted = Encryption.decrypt(string: encrypted, id: id, level: level)
            decrypted_again = Encryption.decrypt(string: decrypted, id: id, level: level)

            decrypted.should eq decrypted_again
          end

          it "#encrypt" do
            plaintext = Faker::Internet.password(10, 20)
            id = UUID.random.to_s

            encrypted = Encryption.encrypt(string: plaintext, id: id, level: level)
            encrypted_again = Encryption.encrypt(string: encrypted, id: id, level: level)
            encrypted.should eq encrypted_again
          end
        end
      end
    end
  end
end
