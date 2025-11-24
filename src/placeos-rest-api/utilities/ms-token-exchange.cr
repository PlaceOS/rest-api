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

    record PeekInfo,
      aud_raw : String,
      aud_host : String,
      email : String?,
      tid : String?,
      iss : String?,
      iss_host : String?,
      version : TokenVersion,
      kid : String? do
      # Basic heuristic to detect Microsoft Entra / Azure AD issuers
      def is_ms_token? : Bool
        iss_val = iss_host
        return false unless iss_val
        iss_val = iss_val.downcase
        iss_val.ends_with?("microsoftonline.com") ||
          iss_val.ends_with?("sts.windows.net") ||
          iss_val.ends_with?("login.windows.net") ||
          iss_val.ends_with?("login.chinacloudapi.cn") ||           # China cloud
          iss_val.ends_with?("login.microsoftonline.de") ||         # Germany
          iss_val.ends_with?("login.partner.microsoftonline.cn") || # 21V
          iss_val.ends_with?("login-us.microsoftonline.com")        # GCC/DoD
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

      # validate the MS token
      payload = validate_token_with_jwks(token, token_info: info)

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
      form = URI::Params.build do |form|
        form.add "grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"
        form.add "client_id", oauth.client_id
        form.add "client_secret", oauth.client_secret
        form.add "assertion", token
        form.add "scope", oauth.scope
        form.add "requested_token_use", "on_behalf_of"
        form.add "resource", "https://graph.microsoft.com/"
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
      begin
        uri = URI.parse(aud_raw)
        uri.host || aud_raw
      rescue
        aud_raw
      end
    end

    # ---------- Issuer Parsing ----------

    def extract_issuer_host(iss_raw : String) : String?
      begin
        uri = URI.parse(iss_raw)
        uri.host
      rescue
        nil
      end
    end

    # ---------- Validation (JWKS) ----------

    class_getter jwks : JWT::JWKS { JWT::JWKS.new }

    def validate_token_with_jwks(
      token : String,
      token_info : PeekInfo? = nil,
    ) : JSON::Any
      info = token_info || peek_token_info(token)
      jwks = MSTokenExchange.jwks
      payload = jwks.validate(
        token,
        validate_claims: true
      ) || raise "token validation failed"

      payload
    end
  end
end
