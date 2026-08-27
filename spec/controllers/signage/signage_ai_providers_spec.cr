require "../../helper"

module PlaceOS::Api
  describe SignageAIProviders do
    base = SignageAIProviders.base_route

    # `Spec.before_each` registers against the root context and would run for
    # every example in the suite. This hook has to stay local, because turning
    # live connections off suite wide would break the specs that talk to core.
    before_each do
      Model::SignageAIJob.clear
      Model::SignageAIProvider.clear
      WebMock.allow_net_connect = false
    end

    it "lets a sys_admin add a provider without ever echoing the credentials" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!

      body = {
        name:          "openai-#{random_name}",
        provider:      "OPENAI",
        authority_id:  authority.id,
        credentials:   {api_key: "sk-spec-secret"},
        default_model: "gpt-image-2",
        is_default:    true,
      }.to_json

      result = client.post(base, headers: Spec::Authentication.headers, body: body)

      result.status_code.should eq 201
      result.body.should_not contain "credentials"
      result.body.should_not contain "sk-spec-secret"

      rendered = JSON.parse(result.body)
      rendered["provider"].as_s.should eq "OPENAI"
      rendered["is_default"].as_bool.should be_true

      row = Model::SignageAIProvider.find!(UUID.new(rendered["id"].as_s))
      row.credentials_encrypted?.should be_true
      row.credentials_json["api_key"].as_s.should eq "sk-spec-secret"
    end

    it "keeps the stored credentials when an update leaves them out" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      provider = Model::Generator.signage_ai_provider(
        authority: authority,
        name: "openai-#{random_name}",
        credentials: %({"api_key":"keep-me"}),
      ).save!

      result = client.patch(
        File.join(base, provider.id.to_s),
        headers: Spec::Authentication.headers,
        body: {name: "renamed", enabled: false}.to_json,
      )

      result.status_code.should eq 200
      result.body.should_not contain "keep-me"

      row = Model::SignageAIProvider.find!(provider.id.as(UUID))
      row.name.should eq "renamed"
      row.enabled.should be_false
      row.credentials_json["api_key"].as_s.should eq "keep-me"
    end

    it "lets support read, and nothing more" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      provider = Model::Generator.signage_ai_provider(
        authority: authority,
        name: "openai-#{random_name}",
      ).save!
      headers = Spec::Authentication.headers(sys_admin: false, support: true)

      index = client.get(base, headers: headers)
      index.status_code.should eq 200
      index.body.should_not contain "credentials"
      JSON.parse(index.body).as_a.map(&.["id"].as_s).should contain provider.id.to_s

      show = client.get(File.join(base, provider.id.to_s), headers: headers)
      show.status_code.should eq 200
      show.body.should_not contain "api_key"

      create = client.post(
        base,
        headers: headers,
        body: {name: "nope", credentials: {api_key: "k"}}.to_json,
      )
      create.status_code.should eq 403

      destroy = client.delete(File.join(base, provider.id.to_s), headers: headers)
      destroy.status_code.should eq 403
      Model::SignageAIProvider.find?(provider.id.as(UUID)).should_not be_nil
    end

    it "keeps a regular user out entirely" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      provider = Model::Generator.signage_ai_provider(
        authority: authority,
        name: "openai-#{random_name}",
      ).save!
      _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

      client.get(base, headers: headers).status_code.should eq 403
      client.get(File.join(base, provider.id.to_s), headers: headers).status_code.should eq 403

      create = client.post(
        base,
        headers: headers,
        body: {name: "nope", credentials: {api_key: "k"}}.to_json,
      )
      create.status_code.should eq 403
    end

    describe "the credentials test" do
      it "reports a working provider" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        provider = Model::Generator.signage_ai_provider(
          authority: authority,
          name: "openai-#{random_name}",
        ).save!

        HttpMocks.signage_ai_vendor(candidates: 1)

        result = client.post(File.join(base, provider.id.to_s, "test"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["ok"].as_bool.should be_true
        body["model"].as_s.should eq "gpt-image-2"
      end

      it "reports a refusal as a moderation failure rather than an error" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        provider = Model::Generator.signage_ai_provider(
          authority: authority,
          name: "openai-#{random_name}",
        ).save!

        HttpMocks.signage_ai_vendor_refused

        result = client.post(File.join(base, provider.id.to_s, "test"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["ok"].as_bool.should be_false
        body["kind"].as_s.should eq "moderation"
      end
    end
  end
end
