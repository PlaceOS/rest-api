require "../helper"

module PlaceOS::Api
  describe ApiKeys do
    _, scoped_headers = Spec::Authentication.x_api_authentication
    before_all { _, scoped_headers = Spec::Authentication.x_api_authentication }

    Spec.test_404(ApiKeys.base_route, model_name: Model::ApiKey.table_name)

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

    describe "embedded user" do
      secret_fields = %w[password password_digest access_token refresh_token expires_at expires]

      it "is the admin view, without the owner's password digest or SSO tokens" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        tag = Random::Secure.hex(6)
        owner = Model::Generator.user(authority: authority)
        owner.password = "s3cr3t-p@ssw0rd"
        owner.access_token = "ms-access-token-#{tag}"
        owner.refresh_token = "ms-refresh-token-#{tag}"
        owner.expires_at = 1.hour.from_now.to_unix
        owner.expires = true
        owner.save!

        key = Model::ApiKey.new(name: "key-#{tag}")
        key.user = owner
        key.save!

        result = client.get(ApiKeys.base_route + key.id.as(String), headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body).as_h
        body["id"].as_s.should eq key.id
        body["user_id"].as_s.should eq owner.id
        embedded = body["user"].as_h
        embedded["id"].as_s.should eq owner.id
        (embedded.keys & secret_fields).should be_empty
        # admin view, so admin-only fields are kept
        embedded.has_key?("sys_admin").should be_true

        result.body.should_not contain(owner.password_digest.as(String))
        result.body.should_not contain(owner.access_token.as(String))
        result.body.should_not contain(owner.refresh_token.as(String))

        index = client.get(ApiKeys.base_route, headers: Spec::Authentication.headers)
        index.status_code.should eq 200
        index.body.should_not contain(owner.password_digest.as(String))
        index.body.should_not contain(owner.access_token.as(String))

        key.destroy
        owner.destroy
      end

      it "create still returns the key once" do
        owner = Spec::Authentication.user
        params = {name: "key-#{Random::Secure.hex(6)}", user_id: owner.id, scopes: ["public"]}
        result = client.post(ApiKeys.base_route, body: params.to_json, headers: Spec::Authentication.headers)
        result.status_code.should eq 201

        body = JSON.parse(result.body).as_h
        body["x_api_key"].as_s.should start_with("#{body["id"].as_s}.")
        body["user"]["id"].as_s.should eq owner.id
        body.has_key?("created_at").should be_true

        Model::ApiKey.find!(body["id"].as_s).destroy
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
