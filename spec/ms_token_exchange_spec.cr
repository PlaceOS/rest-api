require "./helper"
require "jwt"

module PlaceOS::Api
  # `Utils::MSTokenExchange` accepts Microsoft Entra access tokens as bearer
  # tokens. Entra's discovery documents and JWKS are stubbed with a spec key
  # pair. The refusal cases are forged tokens that must never resolve to a
  # PlaceOS user.
  describe Utils::MSTokenExchange do
    # A tenant and client unique to this run: keeps the module's JWKS cache
    # and the global `client_id` strat lookup isolated from other specs.
    tenant = UUID.random.to_s
    other_tenant = UUID.random.to_s
    entra_client = UUID.random.to_s
    kid = "spec-entra-key"
    fixtures = File.join(__DIR__, "fixtures/entra")
    signing_key = File.read(File.join(fixtures, "signing_key.pem"))
    attacker_key = File.read(File.join(fixtures, "attacker_key.pem"))
    jwks_uri = "https://login.microsoftonline.com/#{tenant}/discovery/keys"
    v1_issuer = "https://sts.windows.net/#{tenant}/"
    v2_issuer = "https://login.microsoftonline.com/#{tenant}/v2.0"

    authority = -> { Model::Authority.find_by_domain("localhost").not_nil! }

    make_strat = ->(token_url : String) {
      Model::OAuthAuthentication.where(client_id: entra_client).each(&.destroy)
      strat = Model::OAuthAuthentication.new(
        name: "Entra",
        client_id: entra_client,
        client_secret: "entra-secret",
        site: "https://login.microsoftonline.com",
        authorize_url: "/#{tenant}/oauth2/v2.0/authorize",
        token_url: token_url,
        scope: "openid email offline_access User.Read",
      )
      strat.authority_id = authority.call.id
      strat.save!
    }

    entra_token = ->(overrides : Hash(String, String | Int64 | Nil), key : String) {
      now = Time.utc.to_unix
      claims = {
        "aud"         => entra_client,
        "iss"         => v1_issuer,
        "iat"         => now - 60,
        "nbf"         => now - 60,
        "exp"         => now + 3600,
        "ver"         => "1.0",
        "tid"         => tenant,
        "oid"         => UUID.random.to_s,
        "scp"         => "access_as_user",
        "name"        => "FNU LNU",
        "given_name"  => "FNU",
        "family_name" => "LNU",
        "upn"         => "ms-#{random_name}@example.onmicrosoft.com",
      } of String => String | Int64 | Nil
      overrides.each { |claim, value| value.nil? ? claims.delete(claim) : (claims[claim] = value) }
      JWT.encode(claims, key, JWT::Algorithm::RS256, kid: kid, x5t: kid)
    }

    no_override = {} of String => String | Int64 | Nil
    default_token_url = "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token"

    before_each do
      WebMock.allow_net_connect = false
      {
        "https://login.microsoftonline.com/#{tenant}"      => v1_issuer,
        "https://login.microsoftonline.com/#{tenant}/v2.0" => v2_issuer,
        v1_issuer.rchop('/')                               => v1_issuer,
      }.each do |base, issuer|
        WebMock.stub(:get, "#{base}/.well-known/openid-configuration").to_return(
          status: 200,
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: {issuer: issuer, jwks_uri: jwks_uri}.to_json,
        )
      end
      WebMock.stub(:get, jwks_uri).to_return(
        status: 200,
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: File.read(File.join(fixtures, "jwks.json")),
      )
      # On-behalf-of Graph token requests (endpoint follows the token version)
      {"oauth2/token", "oauth2/v2.0/token"}.each do |path|
        WebMock.stub(:post, "https://login.microsoftonline.com/#{tenant}/#{path}").to_return(
          status: 400, body: %({"error":"invalid_grant"}),
        )
      end
    end

    describe "ms_token?" do
      it "recognises Entra issuers" do
        {
          "https://sts.windows.net/#{tenant}/",
          "https://login.microsoftonline.com/#{tenant}/v2.0",
          "https://login.microsoftonline.us/#{tenant}/v2.0",
        }.each do |iss|
          token = entra_token.call({"iss" => iss} of String => String | Int64 | Nil, signing_key)
          Utils::MSTokenExchange.peek_token_info(token).ms_token?.should be_true
        end
      end

      it "does not match look-alike hosts" do
        {
          "https://evilmicrosoftonline.com/#{tenant}/",
          "https://evilsts.windows.net/#{tenant}/",
          "https://sts.windows.net.evil.com/#{tenant}/",
          "https://login.microsoftonline.com.evil.com/#{tenant}/v2.0",
        }.each do |iss|
          token = entra_token.call({"iss" => iss} of String => String | Int64 | Nil, signing_key)
          Utils::MSTokenExchange.peek_token_info(token).ms_token?.should be_false
        end
      end
    end

    describe "configured_tenant" do
      it "reads the tenant from absolute and site-relative token URLs" do
        strat = Model::OAuthAuthentication.new(name: "x", client_id: "x", client_secret: "x", scope: "x",
          site: "https://login.microsoftonline.com", token_url: "/#{tenant}/oauth2/v2.0/token")
        Utils::MSTokenExchange.configured_tenant(strat).should eq({"login.microsoftonline.com", tenant})

        strat.token_url = default_token_url
        Utils::MSTokenExchange.configured_tenant(strat).should eq({"login.microsoftonline.com", tenant})
      end

      it "has no tenant for multi-tenant, non-Entra or plain-http strats" do
        {
          "https://login.microsoftonline.com/common/oauth2/v2.0/token",
          "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
          "https://evilmicrosoftonline.com/#{tenant}/oauth2/v2.0/token",
          "http://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token",
          "https://accounts.google.com/o/oauth2/token",
        }.each do |url|
          strat = Model::OAuthAuthentication.new(name: "x", client_id: "x", client_secret: "x", scope: "x",
            site: "https://login.microsoftonline.com", token_url: url)
          Utils::MSTokenExchange.configured_tenant(strat).should be_nil
        end
      end
    end

    describe "validate_token_with_jwks" do
      it "refuses a token from another issuer before fetching anything" do
        token = entra_token.call({"iss" => "https://evil.example.com/#{tenant}/"} of String => String | Int64 | Nil, signing_key)
        expect_raises(Exception, "token issuer mismatch") do
          Utils::MSTokenExchange.validate_token_with_jwks(token, issuer: v1_issuer)
        end
      end
    end

    describe "obtain_place_user" do
      it "creates the user for a valid v1 token" do
        make_strat.call(default_token_url)
        upn = "ms-#{random_name}@example.onmicrosoft.com"
        user = Utils::MSTokenExchange.obtain_place_user(entra_token.call({"upn" => upn} of String => String | Int64 | Nil, signing_key)).not_nil!
        user.email.to_s.should eq upn
        user.authority_id.should eq authority.call.id
        user.first_name.should eq "FNU"
        user.last_name.should eq "LNU"
      end

      it "returns the existing user" do
        make_strat.call(default_token_url)
        existing = Model::Generator.user(authority.call).save!
        token = entra_token.call({"upn" => existing.email.to_s} of String => String | Int64 | Nil, signing_key)
        Utils::MSTokenExchange.obtain_place_user(token).try(&.id).should eq existing.id
      end

      it "accepts a v2 token" do
        make_strat.call(default_token_url)
        token = entra_token.call({"iss" => v2_issuer, "ver" => "2.0"} of String => String | Int64 | Nil, signing_key)
        Utils::MSTokenExchange.obtain_place_user(token).should_not be_nil
      end

      it "refuses a token from a look-alike issuer" do
        make_strat.call(default_token_url)
        token = entra_token.call({"iss" => "https://evilmicrosoftonline.com/#{tenant}/"} of String => String | Int64 | Nil, attacker_key)
        Utils::MSTokenExchange.obtain_place_user(token).should be_nil
      end

      it "refuses a token signed by a key the tenant does not publish" do
        make_strat.call(default_token_url)
        token = entra_token.call(no_override, attacker_key)
        expect_raises(Exception, "token validation failed") do
          Utils::MSTokenExchange.obtain_place_user(token)
        end
      end

      it "refuses a token from another tenant" do
        make_strat.call(default_token_url)
        token = entra_token.call({"iss" => "https://sts.windows.net/#{other_tenant}/", "tid" => other_tenant} of String => String | Int64 | Nil, signing_key)
        Utils::MSTokenExchange.obtain_place_user(token).should be_nil
      end

      it "refuses a token whose issuer is another tenant's but tid is ours" do
        make_strat.call(default_token_url)
        token = entra_token.call({"iss" => "https://sts.windows.net/#{other_tenant}/"} of String => String | Int64 | Nil, signing_key)
        Utils::MSTokenExchange.obtain_place_user(token).should be_nil
      end

      it "refuses tokens for a multi-tenant strat" do
        make_strat.call("https://login.microsoftonline.com/common/oauth2/v2.0/token?tenant=#{tenant}")
        Utils::MSTokenExchange.obtain_place_user(entra_token.call(no_override, signing_key)).should be_nil
      end

      it "refuses an expired token" do
        make_strat.call(default_token_url)
        token = entra_token.call({"exp" => Time.utc.to_unix - 600} of String => String | Int64 | Nil, signing_key)
        expect_raises(Exception, "token validation failed") do
          Utils::MSTokenExchange.obtain_place_user(token)
        end
      end

      it "refuses a token for an unknown audience" do
        make_strat.call(default_token_url)
        token = entra_token.call({"aud" => "00000003-0000-0000-c000-000000000000"} of String => String | Int64 | Nil, signing_key)
        Utils::MSTokenExchange.obtain_place_user(token).should be_nil
      end
    end

    describe "as a bearer token" do
      current = ->(token : String) {
        client.get("/api/engine/v2/users/current", headers: HTTP::Headers{
          "Host"          => "localhost",
          "Authorization" => "Bearer #{token}",
        })
      }

      it "authenticates a valid Entra token" do
        make_strat.call(default_token_url)
        upn = "ms-#{random_name}@example.onmicrosoft.com"
        result = current.call(entra_token.call({"upn" => upn} of String => String | Int64 | Nil, signing_key))
        result.status_code.should eq 200
        JSON.parse(result.body)["email"].as_s.should eq upn
      end

      it "rejects a forged token from a look-alike issuer" do
        make_strat.call(default_token_url)
        token = entra_token.call({"iss" => "https://evilmicrosoftonline.com/#{tenant}/"} of String => String | Int64 | Nil, attacker_key)
        current.call(token).status_code.should eq 401
      end

      it "rejects a forged token signed with an attacker key" do
        make_strat.call(default_token_url)
        current.call(entra_token.call(no_override, attacker_key)).status_code.should eq 401
      end

      it "rejects a token from another tenant" do
        make_strat.call(default_token_url)
        token = entra_token.call({"iss" => "https://sts.windows.net/#{other_tenant}/", "tid" => other_tenant} of String => String | Int64 | Nil, signing_key)
        current.call(token).status_code.should eq 401
      end
    end
  end
end
