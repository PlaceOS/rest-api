require "../helper"

module PlaceOS::Api
  describe ApiKeys do
    _, scoped_headers = Spec::Authentication.x_api_authentication
    before_all { _, scoped_headers = Spec::Authentication.x_api_authentication }

    Spec.test_404(ApiKeys.base_route, model_name: Model::ApiKey.table_name, headers: Spec::Authentication.headers)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::ApiKey, ApiKeys)

      it "filters by authority_id" do
        other_authority = PlaceOS::Model::Generator.authority("other-#{random_name}.example.com")
        other_authority.save!

        other_key = PlaceOS::Model::Generator.api_key(other_authority)
        other_key.save!

        # a key under the default (localhost) authority must be excluded
        local_key = PlaceOS::Model::Generator.api_key
        local_key.save!

        params = HTTP::Params.encode({"authority_id" => other_authority.id.as(String)})
        result = client.get(
          "#{ApiKeys.base_route}?#{params}",
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq 200
        keys = Array(Hash(String, JSON::Any)).from_json(result.body)
        ids = keys.map(&.["id"].as_s)
        ids.should contain(other_key.id)
        ids.should_not contain(local_key.id)
        keys.each &.["authority_id"].as_s.should eq other_authority.id

        other_key.destroy
        local_key.destroy
        other_authority.destroy
      end
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
