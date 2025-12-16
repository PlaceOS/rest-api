require "office365"
require "./application"

module PlaceOS::Api
  class TenantConsent < Application
    base "/api/engine/v2/admin_consent"

    skip_action :authorize!, only: [:index, :azure_admin_consent_callback]
    skip_action :set_user_id, only: [:index, :azure_admin_consent_callback]

    @[AC::Route::Filter(:before_action)]
    def get_host
      unless host = request.hostname
        Log.warn { "Host header not found" }
        raise Error::NotFound.new("Unable to get host from request")
      end
      scheme = request.headers["Scheme"]? || "https"
      @redirect_url = "#{scheme}://#{host}#{self.base_route}/callback"
    end

    getter! redirect_url : String

    @[AC::Route::GET("/:id")]
    def index(id : String) : NamedTuple(url: String)
      authority = ::PlaceOS::Model::Authority.find!(id)
      update_app_redirect_uri
      callback_url = URI.encode_www_form(redirect_url)
      consent_url = "https://login.microsoftonline.com/common/adminconsent?client_id=#{PLACE_APP_CLIENT_ID}&redirect_uri=#{callback_url}&state=#{authority.id.as(String)}"
      render json: {"url": consent_url}
    end

    @[AC::Route::GET("/callback")]
    def azure_admin_consent_callback(
      @[AC::Param::Info(description: "Azure AD tenant identifier", example: "abc123")]
      tenant : String? = nil,
      @[AC::Param::Info(description: "Indicates if admin consent was granted", example: "True")]
      admin_consent : Bool? = nil,
      @[AC::Param::Info(description: "Custom state (sent in state param)", example: "uuid-1234")]
      state : String? = nil,
      @[AC::Param::Info(description: "Error code if consent failed", example: "access_denied")]
      error : String? = nil,
      @[AC::Param::Info(description: "Description of the error", example: "The admin denied the request")]
      error_description : String? = nil,
    ) : Nil
      redirect_back = "/backoffice/#/domains/"
      if ((consent = admin_consent) && consent) && (tenant_id = tenant) && (authority_id = state)
        Log.info { "Received admin consent for tenant #{tenant_id} under authority #{authority_id}" }
        authority = ::PlaceOS::Model::Authority.find?(authority_id)
        raise Error::NotFound.new("Invalid state value returned in admin consent") unless authority
        begin
          redirect_back = "#{redirect_back}/#{authority_id}/authentication"
          _ = create_app(tenant_id)
          strat = create_strat(tenant_id, authority.id.as(String))
          auth_app = create_delegated_app(tenant_id, authority.domain, strat.id.as(String))
          strat.update!(client_id: auth_app[:client_id], client_secret: auth_app[:client_secret])
          update_auth(authority, strat.id.as(String))
        ensure
          update_app_redirect_uri(false)
        end
      else
        Log.warn { {message: "Admin declined consent", error: error.to_s, description: error_description.to_s} }
      end
      redirect_to redirect_back, status: :see_other
    end

    private def create_app(tenant_id : String)
      ra = Office365::RequiredResourceAccess.graph_resource_access
      ra << {id: "ef54d2bf-783f-4e0f-bca1-3210c0444d99", type: "Role"} # Calendars.ReadWrite
      ra << {id: "5b567255-7703-4780-807c-7be8301ae99b", type: "Role"} # Group.Read.All
      ra << {id: "df021288-bdef-4463-88db-98f22de89214", type: "Role"} # User.Read.All

      client = get_client(tenant_id)

      app = Office365::Application.single_tenant_app("PlaceOS Bookings Visualiser")
        .add_required_resource(ra)

      created_app = client.create_application(app)
      Log.debug { {message: "App registerd with Application permissions", tenant: tenant_id, client_id: created_app.app_id.as(String)} }

      ra.each do |resource|
        client.application_add_app_role_assignment(created_app.app_id.as(String), resource["id"])
      end

      created_app.app_id.as(String)
    end

    private def create_delegated_app(tenant_id : String, domain : String, strat_id : String)
      ra = Office365::RequiredResourceAccess.graph_resource_access
      ra << {id: "1ec239c2-d7c9-4623-a91a-a9775856bb36", type: "Scope"} # Calendars.ReadWrite
      ra << {id: "12466101-c9b8-439a-8589-dd09ee67e8e9", type: "Scope"} # Calendars.ReadWrite.Shared
      ra << {id: "5f8c59db-677d-491f-a6b8-5f174b11ec1d", type: "Scope"} # Group.Read.All
      ra << {id: "a154be20-db9c-4678-8ab7-66f6cc099a59", type: "Scope"} # User.Read.All
      ra << {id: "7427e0e9-2fba-42fe-b0c0-848c9e6a8182", type: "Scope"} # offline_access
      ra << {id: "37f7f235-527c-4136-accd-4a02d197296e", type: "Scope"} # openid
      ra << {id: "14dad69e-099b-42c9-810b-d002981feec1", type: "Scope"} # profile

      client = get_client(tenant_id)

      app = Office365::Application.single_tenant_app("PlaceOS User Authentication")
        .add_web_redirect_uri("https://#{domain}/auth/oauth2/callback?id=#{strat_id}")
        .add_required_resource(ra)

      created_app = client.create_application(app)
      Log.debug { {message: "App registerd with Delegated permissions", tenant: tenant_id, client_id: created_app.app_id.as(String)} }

      client.application_add_oauth2_permission_grant(created_app.app_id.as(String), "Calendars.ReadWrite Calendars.ReadWrite.Shared Group.Read.All User.Read.All offline_access openid profile")
      secret = client.application_add_pwd(created_app.app_id.as(String), "PlaceOS User Auth Secret")
      {client_id: created_app.app_id.as(String), client_secret: secret.secret_text.as(String)}
    end

    private def get_client(tenant_id = PLACE_APP_TENANT_ID)
      Office365::Client.new(tenant_id, PLACE_APP_CLIENT_ID, PLACE_APP_CLIENT_SECRET)
    end

    private def update_app_redirect_uri(add : Bool = true) : Nil
      client = get_client
      app = client.get_application(PLACE_APP_CLIENT_ID, "id,web")
      app_redirect_uris = app.web.try &.redirect_uris || [] of String

      return nil if add && app_redirect_uris.includes?(redirect_url)
      return nil if !add && !app_redirect_uris.includes?(redirect_url)

      if add
        app_redirect_uris.push(redirect_url)
      else
        app_redirect_uris.delete(redirect_url)
      end
      app.web.not_nil!.redirect_uris = app_redirect_uris
      web = {"web" => app.web}
      begin
        client.update_application(PLACE_APP_CLIENT_ID, web.to_json)
      rescue ex : Office365::Exception
        return nil if already_exists_error?(ex.http_body)
        raise ex
      end
    end

    private def already_exists_error?(error_msg) : Bool
      error = JSON.parse(error_msg)
      error.as_h["error"].as_h["message"] == "One or more properties contains invalid values."
    rescue Exception
      false
    end

    private def create_strat(tenant_id : String, authority_id : String) : ::PlaceOS::Model::OAuthAuthentication
      ::PlaceOS::Model::OAuthAuthentication.create(
        name: "Microsoft AD", authority_id: authority_id, authorize_url: "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/authorize",
        token_url: "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token", site: "https://login.microsoft.com",
        raw_info_url: "https://graph.microsoft.com/v1.0/me", scope: "openid offline_access calendars.readwrite.shared group.read.all user.read.all",
        client_id: "", client_secret: "",
        info_mappings: {
          "email"         => "mail,userPrincipalName",
          "first_name"    => "givenName",
          "last_name"     => "surname",
          "uid"           => "id",
          "access_token"  => "token",
          "refresh_token" => "refresh_token",
          "expires"       => "expires",
          "expires_at"    => "expires_at",
        },
      )
    end

    private def update_auth(authority : ::PlaceOS::Model::Authority, strat_id : String)
      authority.update!(login_url: "/auth/login?provider=oauth2&id=#{strat_id}&continue={{url}}",
        logout_url: "/auth/logout?continue=https://login.microsoftonline.com/common/oauth2/logout?post_logout_redirect_uri=https%3a%2f%2fplaceos.com")
    end
  end
end
