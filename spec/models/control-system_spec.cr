require "../helper"

module Engine::Model
  describe ControlSystem do
    it "saves a control system" do
      cs = Generator.control_system
      begin
        cs.save!
      rescue e : RethinkORM::Error::DocumentInvalid
        inspect_error(e)
        raise e
      end

      cs.should_not be_nil
      id = cs.id
      id.should start_with "sys-" if id
      cs.persisted?.should be_true
    end

    describe "settings" do
      it "encrypts on save" do
        sys = Generator.control_system
        sys.settings = old_settings = [{Encryption::Level::NeverDisplay, %({"secret_key": "secret1234"})}]
        sys.save!
        encrypted_settings = sys.settings.not_nil!

        encrypted_settings.should_not eq old_settings
        encrypted_settings[0][1].should start_with '\e'
      end

      describe "#decrypt_for!" do
        mock_settings = [
          {Encryption::Level::None, %({"sla": "99.?"})},
          {Encryption::Level::Support, %({"whales": "victor mcwhale"})},
          {Encryption::Level::Admin, %({"tax_haven": "seychelles"})},
          {Encryption::Level::NeverDisplay, %({"secret_key": "secret1234"})},
        ]

        it "decrypts for unprivileged" do
          sys = Generator.control_system
          user = Generator.user

          sys.settings = mock_settings.dup
          sys.save!

          encrypted_settings = sys.settings.not_nil!
          encrypted_settings.all? { |s| is_encrypted?(s[1].as(String)) }

          sys.decrypt_for!(user)

          is_encrypted?(sys.settings_at(Encryption::Level::None).as(String)).should be_false
          is_encrypted?(sys.settings_at(Encryption::Level::Support).as(String)).should be_true
          is_encrypted?(sys.settings_at(Encryption::Level::Admin).as(String)).should be_true
          is_encrypted?(sys.settings_at(Encryption::Level::NeverDisplay).as(String)).should be_true
        end

        it "decrypts for support" do
          sys = Generator.control_system
          user = Generator.user
          user.support = true

          sys.settings = mock_settings.dup
          sys.save!

          encrypted_settings = sys.settings.not_nil!
          encrypted_settings.all? { |s| is_encrypted?(s[1].as(String)) }

          sys.decrypt_for!(user)

          is_encrypted?(sys.settings_at(Encryption::Level::None).as(String)).should be_false
          is_encrypted?(sys.settings_at(Encryption::Level::Support).as(String)).should be_false
          is_encrypted?(sys.settings_at(Encryption::Level::Admin).as(String)).should be_true
          is_encrypted?(sys.settings_at(Encryption::Level::NeverDisplay).as(String)).should be_true
        end

        it "decrypts for admin" do
          sys = Generator.control_system
          user = Generator.authenticated_user

          sys.settings = mock_settings.dup
          sys.save!

          encrypted_settings = sys.settings.not_nil!
          encrypted_settings.all? { |s| is_encrypted?(s[1].as(String)) }

          sys.decrypt_for!(user)

          is_encrypted?(sys.settings_at(Encryption::Level::None).as(String)).should be_false
          is_encrypted?(sys.settings_at(Encryption::Level::Support).as(String)).should be_false
          is_encrypted?(sys.settings_at(Encryption::Level::Admin).as(String)).should be_false
          is_encrypted?(sys.settings_at(Encryption::Level::NeverDisplay).as(String)).should be_true
        end
      end
    end

    describe "generation of json data" do
      it "#module_data" do
        cs = Generator.control_system.save!
        modules = [Driver::Role::Logic, Driver::Role::SSH, Driver::Role::Device].map do |role|
          driver = Generator.driver(role: role)
          Generator.module(driver: driver, control_system: cs).save!
        end

        driver_names = modules.compact_map(&.driver.try &.name).sort

        module_ids = modules.compact_map(&.id)
        cs.modules = module_ids

        data = cs.module_data
        module_anys = data.map do |d|
          any = JSON.parse(d).as_h
          any.merge({"driver" => any["driver"].as_h})
        end

        data_driver_names = module_anys.map { |m| m["driver"]["name"].to_s }.sort
        data_driver_names.should eq driver_names

        ids = module_anys.map { |m| m["id"].to_s }
        ids.sort.should eq module_ids.sort
      end

      it "#zone_data" do
        cs = Generator.control_system.save!
        zones = 3.times.to_a.map { |_| Generator.zone.save! }
        zone_ids = zones.compact_map(&.id)
        cs.zones = zone_ids

        data = cs.zone_data
        data.size.should eq 3

        ids = data.map { |d| JSON.parse(d).as_h["id"].to_s }
        ids.sort.should eq zone_ids.sort
      end
    end

    describe "validation" do
      it "rejects invalid support URI" do
        sys = Generator.control_system
        sys.support_url = "string"
        sys.valid?.should be_false
      end
    end

    it "should create triggers when added and removed from a zone" do
      begin
        zone2 = Generator.zone.save!

        cs = Generator.control_system
        zone2_id = zone2.id
        if zone2_id
          cs.zones = [zone2_id]
        end

        cs.save!

        trigger = Trigger.create!(name: "trigger test")
        zone = Generator.zone
        trigger_id = trigger.id
        if trigger_id
          zone.triggers = [trigger_id]
        end
        zone.save!
        zone_id = zone.id
      rescue e : RethinkORM::Error::DocumentInvalid
        inspect_error(e)
        raise e
      end

      cs.triggers.to_a.size.should eq 0

      # Set zones on the ControlSystem
      cs.zones = [zone_id, zone2_id] if zone_id && zone2_id
      cs.save!

      cs = ControlSystem.find! cs.id
      cs.triggers.to_a.size.should eq 1
      cs.triggers.to_a[0].zone_id.should eq zone.id

      cs.zones = [zone2_id] if zone2_id
      cs.save!

      cs = ControlSystem.find! cs.id
      cs.triggers.to_a.size.should eq 0
      zone.trigger_instances.to_a.size.should eq 0

      {cs, zone, zone2, trigger}.each do |m|
        begin
          m.destroy
        rescue
        end
      end
    end
  end
end
