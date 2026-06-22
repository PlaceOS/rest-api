require "../helper"

module PlaceOS::Api
  describe ApiKeys do
    _, scoped_headers = Spec::Authentication.x_api_authentication
    before_all { _, scoped_headers = Spec::Authentication.x_api_authentication }

    Spec.test_404(ApiKeys.base_route, model_name: Model::ApiKey.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::ApiKey, ApiKeys)
    end

    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(Model::ApiKey, ApiKeys)
    end

    describe "scopes" do
      Spec.test_controller_scope(ApiKeys)
    end

    describe "API key expiry", tags: "expiry" do
      it "rejects expired API keys with 401" do
        user, headers = Spec::Authentication.x_api_authentication
        api_key = PlaceOS::Model::ApiKey.where(name: user.email.to_s).first
        api_key.expires_at = Time.utc + 1.second
        api_key.save!
        sleep 1.5.seconds

        result = client.get(path: ApiKeys.base_route + "inspect", headers: headers)
        result.status_code.should eq 401
      end

      it "accepts non-expired API keys" do
        user, headers = Spec::Authentication.x_api_authentication
        api_key = PlaceOS::Model::ApiKey.where(name: user.email.to_s).first
        api_key.expires_at = Time.utc + 1.hour
        api_key.save!

        result = client.get(path: ApiKeys.base_route + "inspect", headers: headers)
        result.status_code.should eq 200
      end

      it "accepts API keys with no expiry set" do
        user, headers = Spec::Authentication.x_api_authentication
        api_key = PlaceOS::Model::ApiKey.where(name: user.email.to_s).first
        api_key.expires_at = nil
        api_key.save!

        result = client.get(path: ApiKeys.base_route + "inspect", headers: headers)
        result.status_code.should eq 200
      end

      it "shows expired keys in index listing" do
        user, _ = Spec::Authentication.x_api_authentication
        api_key = PlaceOS::Model::ApiKey.where(name: user.email.to_s).first
        api_key.expires_at = Time.utc + 1.second
        api_key.save!
        sleep 1.5.seconds

        admin_headers = Spec::Authentication.headers
        result = client.get(path: ApiKeys.base_route, headers: admin_headers)
        result.status_code.should eq 200
      end
    end
  end
end
