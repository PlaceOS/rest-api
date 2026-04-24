require "../../helper"

module PlaceOS::Api
  describe Groups::ApplicationMemberships do
    base = Groups::ApplicationMemberships.base_route

    ::Spec.before_each { clear_group_tables }

    it "sys_admin can create and destroy; non-admin cannot" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      app = Model::Generator.group_application(authority: authority).save!
      group = Model::Generator.group(authority: authority).save!

      payload = {group_id: group.id, application_id: app.id}.to_json

      _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)
      forbidden = client.post(base, body: payload, headers: user_headers)
      forbidden.status_code.should eq 403

      create = client.post(base, body: payload, headers: Spec::Authentication.headers)
      create.status_code.should eq 201

      show_path = File.join(base, group.id.to_s, app.id.to_s)
      show = client.get(show_path, headers: user_headers)
      show.status_code.should eq 200

      delete_forbidden = client.delete(show_path, headers: user_headers)
      delete_forbidden.status_code.should eq 403

      delete = client.delete(show_path, headers: Spec::Authentication.headers)
      delete.success?.should be_true
    end
  end
end
