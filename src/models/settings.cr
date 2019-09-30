require "../encryption"

module Engine::Model
  # Common settings code
  module Settings
    alias Setting = Tuple(Encryption::Level, String)

    # Get settings string for specific encryption level
    #
    def settings_at(level : Encryption::Level) : String?
      @settings.try &.find { |s| s[0] == level }.try &.[1]
    end

    # Encrypts all settings.
    #
    # We want encryption of unpersisted models, so we set the id if not present
    # Setting of id here will not intefer with `persisted?` unless call made in a before_save
    def encrypt_settings(settings : Array(Setting))
      id = (@id ||= @@uuid_generator.next(self))
      settings.map do |setting|
        level, setting_string = setting
        {level, Encryption.encrypt(string: setting_string, level: level, id: id)}
      end
    end

    # Decrypts settings dependent on user privileges
    #
    def decrypt_for!(user)
      id = @id.as(String)
      @settings.as(Array(Setting)).map! do |setting|
        level, setting_string = setting
        case level
        when Encryption::Level::Support
          (user.is_support? || user.is_admin?) ? {level, Encryption.decrypt(string: setting_string, level: level, id: id)} : setting
        when Encryption::Level::Admin
          user.is_admin? ? {level, Encryption.decrypt(string: setting_string, level: level, id: id)} : setting
        else
          setting
        end
      end
    end

    def get_setting_for(user, setting)
      return unless (id = @id)
      @settings.as(Array(Setting)).each do |level, setting_string|
        decrypted = case level
                    when Encryption::Level::Support && (user.is_support? || user.is_admin?)
                      Encryption.decrypt(string: setting_string, level: level, id: id)
                    when Encryption::Level::Admin && user.is_admin?
                      Encryption.decrypt(string: setting_string, level: level, id: id)
                    when Encryption::Level::None
                      Encryption.decrypt(string: setting_string, level: level, id: id)
                    else
                      nil
                    end
        if decrypted
          value = YAML.parse(decrypted)[setting]?
          return value if value
        end
      end

      # No value found
      nil
    end

    # Decrypts all module settings, merges them
    def settings_any
      @settings.as(Array(Setting)).reduce({} of String => YAML::Any) { |acc, (level, settings_string)|
        # Decrypt String
        decrypted = Engine::Encryption.decrypt(string: settings_string, level: level, id: id)
        # Parse and merge into accumulated settings hash
        acc.merge!(YAML.parse(decrypted).as_h)
      }
    end

    # Decrypts settings, merges into single JSON object
    #
    def settings_json
      return unless (id = @id)
      @settings.as(Array(Setting)).reduce({} of String => YAML::Any) { |acc, (level, settings_string)|
        # Decrypt String
        decrypted = Engine::Encryption.decrypt(string: settings_string, level: level, id: id)
        # Parse and merge into accumulated settings hash
        acc.merge!(YAML.parse(decrypted).as_h)
      }.to_json
    end
  end
end
