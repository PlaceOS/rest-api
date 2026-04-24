require "../../helper"

module PlaceOS::Api
  describe Groups::ApplicationDoorkeepers do
    base = Groups::ApplicationDoorkeepers.base_route

    ::Spec.before_each { clear_group_tables }

    it "sys_admin can create and destroy a link; non-admin cannot list, create or destroy" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      app = Model::Generator.group_application(authority: authority).save!
      doorkeeper = Model::Generator.doorkeeper_application(owner: authority).save!

      payload = {
        group_application_id:      app.id,
        doorkeeper_application_id: doorkeeper.id,
      }.to_json

      _, user_headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      client.get(base, headers: user_headers).status_code.should eq 403
      client.post(base, body: payload, headers: user_headers).status_code.should eq 403

      create = client.post(base, body: payload, headers: Spec::Authentication.headers)
      create.status_code.should eq 201

      show_path = File.join(base, app.id.to_s, doorkeeper.id.to_s)
      client.get(show_path, headers: Spec::Authentication.headers).status_code.should eq 200

      delete = client.delete(show_path, headers: Spec::Authentication.headers)
      delete.success?.should be_true
    end
  end
end
