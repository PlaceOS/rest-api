require "../helper"

module PlaceOS::Api
  describe Settings do
    Spec.test_404(Settings.base_route, model_name: Model::Settings.table_name, headers: Spec::Authentication.headers)

    describe "support user" do
      context "access" do
        it "index" do
          _, support_header = Spec::Authentication.authentication(sys_admin: false, support: true)
          sys = Model::Generator.control_system.save!
          setting = Model::Generator.settings(encryption_level: Encryption::Level::None, control_system: sys)
          setting.settings_string = "tree: 1"
          setting.save!
          result = client.get(
            path: File.join(Settings.base_route, "?parent_id=#{sys.id}"),
            headers: support_header,
          )

          result.status_code.should eq 200
        end

        it "show" do
          _, support_header = Spec::Authentication.authentication(sys_admin: false, support: true)
          sys = Model::Generator.control_system.save!
          setting = Model::Generator.settings(encryption_level: Encryption::Level::None, control_system: sys)
          setting.settings_string = "tree: 1"
          setting.save!
          result = client.get(
            path: File.join(Settings.base_route, setting.id.as(String)),
            headers: support_header,
          )

          result.status_code.should eq 200
        end
      end
    end

    describe "index", tags: "search" do
      it "searches on keys" do
        unencrypted = %({"secret_key": "secret1234"})
        settings = Model::Generator.settings(settings_string: unencrypted).save!

        sleep 1.seconds
        refresh_elastic(Model::Settings.table_name)

        params = HTTP::Params.encode({"q" => settings.keys.first})
        path = "#{Settings.base_route.rstrip('/')}?#{params}"

        result = client.get(
          path: path,
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq 200

        settings = Array(Model::Settings).from_json(result.body)
        settings.should_not be_empty
        settings.first.keys.should contain("secret_key")
      end

      it "returns settings for a set of parent ids" do
        systems = Array.new(2) { Model::Generator.control_system.save! }

        systems.map do |system|
          {Encryption::Level::None, Encryption::Level::Admin, Encryption::Level::NeverDisplay}.map do |level|
            Model::Generator.settings(encryption_level: level, control_system: system).save!
          end
        end

        sys, sys2 = systems

        refresh_elastic(Model::Settings.table_name)

        result = client.get(
          path: File.join(Settings.base_route, "?parent_id=#{sys.id},#{sys2.id}"),
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq 200

        returned_settings = Array(Model::Settings).from_json(result.body)

        returned_settings.size.should eq(6)

        never_displayed_settings, admin_settings, no_encryption_settings = returned_settings.in_groups_of(2).map(&.compact)

        never_displayed_settings.all?(&.encryption_level.never_display?).should be_true
        admin_settings.all?(&.encryption_level.admin?).should be_true
        no_encryption_settings.all?(&.encryption_level.none?).should be_true
      end

      it "returns settings for parent id" do
        sys = Model::Generator.control_system.save!
        settings = [
          Model::Generator.settings(encryption_level: Encryption::Level::None, control_system: sys),
          Model::Generator.settings(encryption_level: Encryption::Level::Admin, control_system: sys),
          Model::Generator.settings(encryption_level: Encryption::Level::NeverDisplay, control_system: sys),
        ]
        clear, admin, never_displayed = settings.map(&.save!)
        refresh_elastic(Model::Settings.table_name)

        result = client.get(
          path: File.join(Settings.base_route, "?parent_id=#{sys.id}"),
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq 200

        returned_settings = Array(JSON::Any)
          .from_json(result.body)
          .map { |j| Model::Settings.from_trusted_json(j.to_json) }
          .sort_by!(&.encryption_level)

        returned_clear, returned_admin, returned_never_displayed = returned_settings

        returned_clear.id.should eq clear.id
        returned_admin.id.should eq admin.id
        returned_never_displayed.id.should eq never_displayed.id

        returned_clear.is_encrypted?.should be_false
        returned_admin.is_encrypted?.should be_false
        returned_never_displayed.is_encrypted?.should be_true
      end
    end

    describe "GET /settings/:id/history" do
      it "returns history for a master setting" do
        sys = Model::Generator.control_system.save!

        setting = Model::Generator.settings(encryption_level: Encryption::Level::None, control_system: sys)
        setting.settings_string = "tree: 1"
        setting.save!

        Timecop.freeze(3.seconds.from_now) do
          setting.settings_string = "tree: 10"
          setting.save!
        end

        result = client.get(
          path: File.join(Settings.base_route, "/#{setting.id}/history"),
          headers: Spec::Authentication.headers
        )

        result.success?.should be_true
        result.headers["X-Total-Count"].should eq "2"
        result.headers["Content-Range"].should eq "sets 0-2/2"

        Array(JSON::Any).from_json(result.body).size.should eq 2

        result = client.get(
          path: File.join(Settings.base_route, "/#{setting.id}/history?limit=1"),
          headers: Spec::Authentication.headers
        )

        link = %(</api/engine/v2/settings/#{setting.id}/history?limit=1&offset=2>; rel="next")
        result.success?.should be_true
        result.headers["X-Total-Count"].should eq "2"
        result.headers["Content-Range"].should eq "sets 0-1/2"
        result.headers["Link"].should eq link

        {sys, setting}.each &.destroy
      end
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(klass: Model::Settings, controller_klass: Settings)
      it "update" do
        settings = Model::Generator.settings(encryption_level: Encryption::Level::None).save!
        original_settings = settings.settings_string
        settings.settings_string = %(hello: "world"\n)

        id = settings.id.as(String)
        path = File.join(Settings.base_route, id)
        result = client.patch(
          path: path,
          body: settings.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::Settings.from_trusted_json(result.body)

        updated.id.should eq settings.id
        updated.settings_string.should_not eq original_settings
        updated.destroy
      end
    end

    describe "scopes" do
      Spec.test_controller_scope(Settings)

      it "checks scope on update" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("settings", PlaceOS::Model::UserJWT::Scope::Access::Write)])
        settings = Model::Generator.settings(encryption_level: Encryption::Level::None).save!
        original_settings = settings.settings_string
        settings.settings_string = %(hello: "world"\n)

        id = settings.id.as(String)
        path = File.join(Settings.base_route, id)
        result = Scopes.update(path, settings, scoped_headers)

        result.status_code.should eq 200
        updated = Model::Settings.from_trusted_json(result.body)

        updated.id.should eq settings.id
        updated.settings_string.should_not eq original_settings
        updated.destroy

        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("settings", PlaceOS::Model::UserJWT::Scope::Access::Read)])
        result = Scopes.update(path, settings, scoped_headers)

        result.success?.should be_false
        result.status_code.should eq 403
      end
    end
  end
end
