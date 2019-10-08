require "openssl"
require "base64"
require "uuid"

# Provides symmetric key encryption/decryption
module ACAEngine::Encryption
  # Privilege levels
  enum Level
    None
    Support
    Admin
    NeverDisplay
  end

  private SECRET = ENV["ENGINE_SECRET"]? || "super secret, do not leak"
  private CIPHER = "aes-256-gcm"

  # Encrypt clear text
  # Does not encrypt
  # - previously encrypted
  # - values with `Level::NoEncryption` encryption
  #
  def self.encrypt(string : String, id : String, level : Level) : String
    return string if level == Level::None || is_encrypted?(string)

    # Create unique key, salt
    salt, key = generate_key(id: id, level: level)

    # Initialise cipher
    cipher = OpenSSL::Cipher.new(CIPHER)
    cipher.encrypt
    cipher.key = key
    cipher.iv = iv = cipher.random_iv

    # Encrypt clear text
    encrypted_data = IO::Memory.new
    encrypted_data.write(cipher.update(string))
    encrypted_data.write(cipher.final)

    # Generate storable value
    "\e#{salt}|#{::Base64.strict_encode(iv)}|#{::Base64.strict_encode(encrypted_data.to_slice)}"
  end

  # Decrypt cipher text.
  # Does not decrypt
  # - previously decrypted
  # - values with `Level::None` encryption
  #
  def self.decrypt(string : String, id : String, level : Level) : String
    return string if level == Level::None || !is_encrypted?(string)

    # Pick off salt, initialisation vector and cipher text embedded in encrypted string
    salt, iv, cipher_text = string[1..-1].split('|')

    _, key = generate_key(id: id, level: level, salt: salt)

    cipher = OpenSSL::Cipher.new(CIPHER)
    cipher.decrypt
    cipher.key = key
    cipher.iv = Base64.decode(iv)

    clear_data = IO::Memory.new
    clear_data.write(cipher.update(::Base64.decode(cipher_text)))

    String.new(clear_data.to_slice)
  end

  # Create a key from user privilege, id and existing/random salt
  #
  protected def self.generate_key(level : Level, id : String, salt : String = UUID.random.to_s)
    digest = OpenSSL::Digest.new("SHA256")
    digest << salt
    digest << SECRET
    digest << id
    digest << level.to_s
    {salt, digest.digest}
  end

  # Check if string has been encrypted
  #
  def self.is_encrypted?(string : String)
    string[0]? == '\e'
  end
end
