require "./helper"

module PlaceOS::Api
  describe Settings do
    _, authorization_header = authentication
    base = Api::Settings::NAMESPACE[0]
    with_server do
      test_404(base, model_name: Model::Settings.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        pending "searchs on keys"
        pending "returns settings for a set of parent ids"
        it "returns settings for parent id" do
          sys = Model::Generator.control_system.save!
          settings = [
            Model::Generator.settings(encryption_level: Encryption::Level::None, control_system: sys),
            Model::Generator.settings(encryption_level: Encryption::Level::Admin, control_system: sys),
            Model::Generator.settings(encryption_level: Encryption::Level::NeverDisplay, control_system: sys),
          ]
          clear, admin, never_displayed = settings.map(&.save!)
          result = curl(
            method: "GET",
            path: File.join(base, "?parent_id=#{sys.id}"),
            headers: authorization_header
          )

          result.status_code.should eq 200
          returned_settings = Array(Model::Settings).from_json(result.body).sort_by!(&.encryption_level.not_nil!)
          returned_clear, returned_admin, returned_never_displayed = returned_settings

          returned_clear.id.should eq clear.id
          returned_admin.id.should eq admin.id
          returned_never_displayed.id.should eq never_displayed.id

          returned_clear.is_encrypted?.should be_false
          returned_admin.is_encrypted?.should be_false
          returned_never_displayed.is_encrypted?.should be_true
        end
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Settings, controller_klass: Settings)
        it "update" do
          settings = Model::Generator.settings(encryption_level: Encryption::Level::None).save!
          original_settings = settings.settings_string.as(String)
          settings.settings_string = %(hello: "world"\n)

          id = settings.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: settings.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Settings.from_json(result.body)

          updated.id.should eq settings.id
          updated.settings_string.should_not eq original_settings
        end
      end
    end
  end
end
