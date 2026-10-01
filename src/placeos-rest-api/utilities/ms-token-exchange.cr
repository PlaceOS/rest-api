require "uri"
require "jwt"
require "jwt/jwks"
require "placeos-models/authority"
require "placeos-models/user"
require "placeos-models/user_jwt"

module PlaceOS::Api
  # Helper to authenticate using an MS token
  # * check the token is valid
  module Utils::MSTokenExchange
    extend self

    enum TokenVersion
      V1
      V2
    end

    # Entra token issuer hosts (public and sovereign clouds)
    MS_ISSUER_HOSTS = {
      "sts.windows.net",
      "login.microsoftonline.com",
      "login.windows.net",
      "login-us.microsoftonline.com",     # GCC/DoD
      "login.microsoftonline.us",         # GCC High
      "login.chinacloudapi.cn",           # China cloud
      "sts.chinacloudapi.cn",             # China cloud (v1)
      "login.partner.microsoftonline.cn", # 21V
      "login.microsoftonline.de",         # Germany
    }

    # Entra sign-in hosts an `oauth_strat` may be configured against
    MS_LOGIN_HOSTS = {
      "login.microsoftonline.com",
      "login.windows.net",
      "login-us.microsoftonline.com",
      "login.microsoftonline.us",
      "login.chinacloudapi.cn",
      "login.partner.microsoftonline.cn",
      "login.microsoftonline.de",
    }

    record PeekInfo,
      aud_raw : String,
      aud_host : String,
      email : String?,
      tid : String?,
      iss : String?,
      iss_host : String?,
      version : TokenVersion,
      kid : String? do
      # Detects Microsoft Entra / Azure AD issuers. This only routes the token
      # to the MS path; trust is established in `obtain_place_user`.
      #
      # Hosts are matched exactly: a suffix match also accepted look-alike
      # domains such as `evilmicrosoftonline.com`.
      def ms_token? : Bool
        iss_val = iss_host
        return false unless iss_val
        MS_ISSUER_HOSTS.includes?(iss_val.downcase)
      end

      def token_endpoint : URI?
        case version
        in .v1?
          URI.parse("https://login.microsoftonline.com/#{tid}/oauth2/token")
        in .v2?
          URI.parse("https://login.microsoftonline.com/#{tid}/oauth2/v2.0/token")
        end
      end
    end

    # ---------- Peek (safe decode, no signature validation) ----------

    def peek_token_info(token : String) : PeekInfo
      payload, header = JWT.decode(token, verify: false, validate: false)

      aud_raw = payload["aud"]?.try(&.as_s) || raise "missing aud"
      iss = payload["iss"]?.try(&.as_s) || raise "missing iss"
      email = payload["upn"]?.try(&.as_s)
      tid = payload["tid"]?.try(&.as_s)
      kid = header["kid"]?.try(&.as_s)

      version = detect_token_version(payload, iss)
      aud_host = extract_aud_host(aud_raw)
      iss_host = extract_issuer_host(iss)

      PeekInfo.new(
        aud_raw: aud_raw,
        aud_host: aud_host,
        email: email,
        tid: tid,
        iss: iss,
        iss_host: iss_host,
        version: version,
        kid: kid
      )
    end

    # obtain MS Graph API token - this is a simple way to validate its authenticity
    def obtain_place_user(token : String, token_info : PeekInfo? = nil) : Model::User?
      info = token_info || peek_token_info(token)
      tenant = info.tid
      email = info.email
      return unless tenant && email
      oauth = Model::OAuthAuthentication.find_by?(client_id: info.aud_host)
      return unless oauth

      # ensure Tenant ID matches our authentication source
      return unless oauth.token_url.includes?(tenant)

      # The issuer (and so the signing keys) must come from the tenant this
      # strat is configured for, never from the token itself. Otherwise anyone
      # hosting a discovery document could sign tokens for any user.
      expected_issuer = configured_issuer(oauth, info)
      unless expected_issuer && info.iss == expected_issuer
        Log.warn { {message: "MS token issuer does not match the configured tenant", issuer: info.iss, expected: expected_issuer} }
        return
      end

      # validate the MS token
      payload = validate_token_with_jwks(token, token_info: info, issuer: expected_issuer)

      # the verified claims must agree with what we looked the strat up by
      return unless payload["tid"]?.try(&.as_s?) == tenant
      return unless payload["upn"]?.try(&.as_s?) == email

      # find the place user or create a new one
      user = Model::User.find_by?(authority_id: oauth.authority_id, email: email.downcase) || create_place_user(oauth, payload)

      # ensure there is a valid MS Graph API access token in place
      # as we maybe attempting to perform graph actions on behalf of the user
      ensure_valid_token(oauth, user, token, info)

      # return the user
      user
    end

    def create_place_user(oauth : Model::OAuthAuthentication, payload : JSON::Any) : Model::User
      Model::User.create!(
        name: payload["name"].as_s,
        last_name: payload["family_name"].as_s,
        first_name: payload["given_name"].as_s,
        email: Model::Email.new(payload["upn"].as_s),
        authority_id: oauth.authority_id
      )
    end

    def ensure_valid_token(oauth : Model::OAuthAuthentication, user : Model::User, token : String, token_info : PeekInfo)
      # return if there is an existing token and valid
      existing = Api::Users.get_user_token(user, oauth.authority.as(Model::Authority)) rescue nil
      return if existing

      # if not existing or refresh failed, get a token using this token and on behalf of
      # https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow#example
      form = URI::Params.build do |builder|
        builder.add "grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"
        builder.add "client_id", oauth.client_id
        builder.add "client_secret", oauth.client_secret
        builder.add "assertion", token
        builder.add "scope", oauth.scope
        builder.add "requested_token_use", "on_behalf_of"
        builder.add "resource", "https://graph.microsoft.com/"
      end

      uri = token_info.token_endpoint

      client = HTTP::Client.new(uri, tls: true)
      client.basic_auth(oauth.client_id, oauth.client_secret)
      response = HTTP::Client.post(
        uri,
        headers: HTTP::Headers{
          "Accept" => "application/json",
        },
        form: form
      )

      if !response.success?
        Log.warn { "failed with #{response.status_code} to obtain token on behalf of #{user.name} (#{user.id})\nbody: #{response.body}" }
        return
      end

      # update the user model with the graph API access token
      token = OAuth2::AccessToken.from_json(response.body)
      user.access_token = token.access_token
      user.refresh_token = token.refresh_token if token.refresh_token
      user.expires_at = Time.utc.to_unix + token.expires_in.not_nil!
      user.save!
    end

    def detect_token_version(payload : JSON::Any, iss : String) : TokenVersion
      ver = payload["ver"]?.try &.as_s?
      return TokenVersion::V2 if ver == "2.0" || iss.includes?("/v2.0")
      TokenVersion::V1
    end

    # ---------- Audience Parsing ----------

    def extract_aud_host(aud_raw : String) : String
      uri = URI.parse(aud_raw)
      uri.host || aud_raw
    rescue
      aud_raw
    end

    # ---------- Issuer Parsing ----------

    def extract_issuer_host(iss_raw : String) : String?
      uri = URI.parse(iss_raw)
      uri.host
    rescue
      nil
    end

    # ---------- Validation (JWKS) ----------

    class_getter jwks : JWT::JWKS { JWT::JWKS.new }

    # `issuer` is required and must come from configuration: when it is
    # omitted the JWKS helper fetches signing keys from the token's own `iss`.
    def validate_token_with_jwks(
      token : String,
      token_info : PeekInfo? = nil,
      *,
      issuer : String,
    ) : JSON::Any
      info = token_info || peek_token_info(token)
      # checked before `validate` so we never fetch metadata from an
      # issuer we don't trust
      raise "token issuer mismatch" unless info.iss == issuer

      jwks = MSTokenExchange.jwks
      payload = jwks.validate(
        token,
        issuer: issuer,
        validate_claims: true
      ) || raise "token validation failed"

      payload
    end

    # ---------- Configured tenant ----------

    # The issuer published by the tenant `oauth` is configured against, for
    # the token's version (v1 and v2 tokens have different issuers).
    # `nil` if the strat is not a tenant-specific Entra strat.
    def configured_issuer(oauth : Model::OAuthAuthentication, token_info : PeekInfo) : String?
      login_host, tenant = configured_tenant(oauth) || return
      base = "https://#{login_host}/#{tenant}"
      base = "#{base}/v2.0" if token_info.version.v2?
      MSTokenExchange.jwks.fetch_oidc_metadata(base).issuer
    rescue error
      Log.warn(exception: error) { "failed to load MS discovery for #{oauth.token_url}" }
      nil
    end

    # `{login host, tenant}` from the strat's token URL, which may be
    # absolute or relative to `site`.
    def configured_tenant(oauth : Model::OAuthAuthentication) : Tuple(String, String)?
      uri = URI.parse(oauth.token_url)
      uri = URI.parse(oauth.site).resolve(uri) unless uri.absolute?
      return unless uri.scheme == "https"

      host = uri.host.try(&.downcase)
      return unless host && MS_LOGIN_HOSTS.includes?(host)

      tenant = uri.path.split('/', remove_empty: true).first?
      return unless tenant
      return if {"common", "organizations", "consumers"}.includes?(tenant.downcase)
      {host, tenant}
    rescue URI::Error
      nil
    end
  end
end
