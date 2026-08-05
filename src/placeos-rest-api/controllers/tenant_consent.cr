require "uuid"
require "office365"
require "./application"

module PlaceOS::Api
  class TenantConsent < Application
    base "/api/engine/v2/admin_consent"

    skip_action :authorize!, only: [:index, :azure_admin_consent_callback, :flow_status]
    skip_action :set_user_id, only: [:index, :azure_admin_consent_callback, :flow_status]

    @[AC::Route::Filter(:before_action)]
    def get_host
      unless @domain_host = request.hostname
        Log.warn { "Host header not found" }
        raise Error::NotFound.new("Unable to get host from request")
      end
      scheme = request.headers["Scheme"]? || "https"
      @redirect_url = "#{scheme}://#{domain_host}#{self.base_route}/callback"
      @domain_url = "#{scheme}://#{domain_host}"
    end

    getter! redirect_url : String
    getter! domain_url : String
    getter! domain_host : String

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
      if ((consent = admin_consent) && consent) && (tenant_id = tenant) && (authority_id = state)
        Log.info { "Received admin consent for tenant #{tenant_id} under authority #{authority_id}" }
        authority = ::PlaceOS::Model::Authority.find?(authority_id)
        raise Error::NotFound.new("Invalid state value returned in admin consent") unless authority

        flow = AdminConsentFlow.new(UUID.v4.to_s, authority_id, "/backoffice/#/domains/#{authority_id}/authentication")
        flow.save
        @flow = flow

        # The Microsoft Graph work can take minutes when directory replication
        # is slow - run it in a fiber and respond immediately with a progress
        # page that polls the flow status. Request-derived state (domain_host
        # etc.) is already captured in ivars, safe to use after the response.
        spawn { run_consent_flow(flow, tenant_id, authority) }

        render html: progress_page(flow.id)
      else
        Log.warn { {message: "Admin declined consent", error: error.to_s, description: error_description.to_s} }
        redirect_to "/backoffice/#/domains/", status: :see_other
      end
    end

    # progress of an in-flight admin-consent flow, polled by the progress page.
    # The flow id is an unguessable capability token; the payload contains no
    # secrets.
    @[AC::Route::GET("/flow/:flow_id")]
    def flow_status(
      @[AC::Param::Info(description: "Flow identifier issued by the consent callback", example: "uuid-1234")]
      flow_id : String,
    ) : AdminConsentFlow
      flow = AdminConsentFlow.load(flow_id)
      raise Error::NotFound.new("unknown or expired flow") unless flow
      flow
    end

    @flow : AdminConsentFlow? = nil

    private def run_consent_flow(flow : AdminConsentFlow, tenant_id : String, authority : ::PlaceOS::Model::Authority) : Nil
      # Everything this flow configures belongs to the authority being
      # integrated, which is not necessarily the host the admin happens to be
      # browsing - Backoffice can drive the flow for any domain.
      authority_domain = authority.domain

      flow.start_step("visualiser")
      visualiser_app = create_app(tenant_id)

      flow.start_step("calendar")
      self.class.upsert_calendar_tenant(authority_domain, tenant_id, visualiser_app, authority.name)

      flow.start_step("auth_app")
      strat = create_strat(tenant_id, authority.id.as(String))
      auth_app = create_delegated_app(tenant_id, authority_domain, strat.id.as(String))

      flow.start_step("outlook")
      create_outlook_repo
      add_outlook_plugin_auth(auth_app[:client_id], authority_domain)
      create_outlook_config(auth_app[:client_id], authority_domain)

      flow.start_step("saving")
      strat.update!(client_id: auth_app[:client_id], client_secret: auth_app[:client_secret])
      update_auth(authority, strat.id.as(String))

      flow.complete!
      Log.info { {message: "admin consent flow complete", flow_id: flow.id, authority_id: flow.authority_id} }
    rescue error
      Log.error(exception: error) { {message: "admin consent flow failed", flow_id: flow.id, authority_id: flow.authority_id} }
      flow.fail!(error.message || error.class.name)
    end

    # surfaces replication-retry waits on the progress page
    private def replication_progress : Proc(Int32, Nil)?
      return nil unless flow = @flow
      ->(attempt : Int32) { flow.detail("Waiting for Microsoft to replicate (attempt #{attempt})") }
    end

    # Self-contained progress page shown in the consent tab while the fiber
    # works. Polls the flow endpoint; no frontend build involvement.
    private def progress_page(flow_id : String) : String
      <<-HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Microsoft Integration - PlaceOS</title>
      <style>
        :root { color-scheme: light dark; }
        body { margin: 0; font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
               display: flex; align-items: center; justify-content: center; min-height: 100vh;
               background: light-dark(#f5f6f8, #17181c); color: light-dark(#1c1d21, #e8e9ec); }
        .card { width: min(30rem, 92vw); background: light-dark(#ffffff, #212228);
                border-radius: 12px; padding: 2rem 2.25rem; box-shadow: 0 8px 30px rgba(0,0,0,.12); }
        h1 { font-size: 1.15rem; margin: 0 0 .35rem; }
        p.sub { margin: 0 0 1.4rem; font-size: .85rem; opacity: .65; }
        ul { list-style: none; margin: 0; padding: 0; }
        li { display: flex; align-items: center; gap: .65rem; padding: .45rem 0; font-size: .92rem; }
        li .mark { width: 1.15rem; height: 1.15rem; flex: none; border-radius: 50%;
                   display: inline-flex; align-items: center; justify-content: center; font-size: .7rem; }
        li.pending { opacity: .45; }
        li.pending .mark { border: 2px solid currentColor; opacity: .4; }
        li.done .mark { background: #16a34a; color: #fff; }
        li.failed .mark { background: #dc2626; color: #fff; }
        li.running .mark { border: 2px solid #2563eb; border-top-color: transparent;
                           animation: spin   .8s linear infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .detail { min-height: 1.2rem; margin-top: 1rem; font-size: .8rem; opacity: .7; font-style: italic; }
        .error { margin-top: 1rem; padding: .8rem 1rem; border-radius: 8px; font-size: .85rem;
                 background: light-dark(#fee2e2, #3f1d1d); color: light-dark(#991b1b, #fca5a5); display: none; }
        .footer { margin-top: 1.4rem; font-size: .78rem; opacity: .55; }
        a { color: #2563eb; }
      </style>
      </head>
      <body>
      <div class="card">
        <h1>Setting up your Microsoft integration</h1>
        <p class="sub">Microsoft consent accepted &mdash; PlaceOS is registering the applications in your directory. This can take a couple of minutes while Microsoft replicates changes.</p>
        <ul id="steps"></ul>
        <div class="detail" id="detail"></div>
        <div class="error" id="error"></div>
        <div class="footer" id="footer">Elapsed <span id="elapsed">0s</span> &middot; leave this tab open</div>
      </div>
      <script>
        var flowUrl = "/api/engine/v2/admin_consent/flow/#{flow_id}";
        var started = Date.now();
        var misses = 0;
        var finished = false;

        function draw(flow) {
          var list = document.getElementById("steps");
          list.innerHTML = "";
          flow.steps.forEach(function (step) {
            var item = document.createElement("li");
            item.className = step.state;
            var mark = step.state === "done" ? "&#10003;" : step.state === "failed" ? "&#10007;" : "";
            item.innerHTML = '<span class="mark">' + mark + '</span><span>' + step.label + '</span>';
            list.appendChild(item);
          });
          document.getElementById("detail").textContent = flow.detail || "";
          if (flow.state === "complete") {
            finished = true;
            document.getElementById("footer").innerHTML = "Done &mdash; returning to Backoffice&hellip;";
            try { new BroadcastChannel("placeos_admin_consent").postMessage({authority_id: flow.authority_id, state: "complete"}); } catch (ignored) {}
            setTimeout(function () { window.location.href = flow.redirect; }, 1200);
          } else if (flow.state === "failed") {
            finished = true;
            var box = document.getElementById("error");
            box.style.display = "block";
            box.textContent = "The integration could not be completed: " + (flow.error || "unknown error");
            document.getElementById("footer").innerHTML = 'You can close this tab, or <a href="' + flow.redirect + '">return to Backoffice</a> and try again.';
          }
        }

        function poll() {
          if (finished) return;
          fetch(flowUrl).then(function (res) {
            if (!res.ok) throw new Error(res.status);
            return res.json();
          }).then(function (flow) {
            misses = 0;
            draw(flow);
          }).catch(function () {
            misses += 1;
            if (misses > 5) {
              document.getElementById("detail").textContent = "Connection to PlaceOS interrupted - still trying...";
            }
          }).finally(function () {
            if (!finished) setTimeout(poll, 2000);
          });
        }

        setInterval(function () {
          if (finished) return;
          document.getElementById("elapsed").textContent = Math.round((Date.now() - started) / 1000) + "s";
        }, 1000);

        poll();
      </script>
      </body>
      </html>
      HTML
    end

    private def create_app(tenant_id : String)
      ra = Office365::RequiredResourceAccess.graph_resource_access
      ra << {id: "ef54d2bf-783f-4e0f-bca1-3210c0444d99", type: "Role"} # Calendars.ReadWrite
      ra << {id: "5b567255-7703-4780-807c-7be8301ae99b", type: "Role"} # Group.Read.All
      ra << {id: "df021288-bdef-4463-88db-98f22de89214", type: "Role"} # User.Read.All

      client = get_client(tenant_id)

      app = Office365::Application.single_tenant_app("PlaceOS Bookings Visualiser")
        .add_required_resource(ra)

      created_app = GraphReplicationRetry.run(on_retry: replication_progress) { client.create_application(app) }
      Log.debug { {message: "App registerd with Application permissions", tenant: tenant_id, client_id: created_app.app_id.as(String)} }

      ra.each do |resource|
        GraphReplicationRetry.run(on_retry: replication_progress) do
          client.application_add_app_role_assignment(created_app.app_id.as(String), resource["id"])
        end
      end

      secret = GraphReplicationRetry.run(on_retry: replication_progress) { client.application_add_pwd(created_app.app_id.as(String), "PlaceOS Bookings Visualiser Secret") }
      {client_id: created_app.app_id.as(String), client_secret: secret.secret_text.as(String)}
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

      created_app = GraphReplicationRetry.run(on_retry: replication_progress) { client.create_application(app) }
      Log.debug { {message: "App registerd with Delegated permissions", tenant: tenant_id, client_id: created_app.app_id.as(String)} }

      GraphReplicationRetry.run(on_retry: replication_progress) do
        client.application_add_oauth2_permission_grant(created_app.app_id.as(String), "Calendars.ReadWrite Calendars.ReadWrite.Shared Group.Read.All User.Read.All offline_access openid profile")
      end
      secret = GraphReplicationRetry.run(on_retry: replication_progress) { client.application_add_pwd(created_app.app_id.as(String), "PlaceOS User Auth Secret") }
      {client_id: created_app.app_id.as(String), client_secret: secret.secret_text.as(String)}
    end

    private def get_client(tenant_id = PLACE_APP_TENANT_ID)
      Office365::Client.new(tenant_id, PLACE_APP_CLIENT_ID, PLACE_APP_CLIENT_SECRET)
    end

    private def update_app_redirect_uri(add : Bool = true) : Nil
      client = get_client
      app = GraphReplicationRetry.run(on_retry: replication_progress) { client.get_application(PLACE_APP_CLIENT_ID, "id,web") }
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
        GraphReplicationRetry.run(on_retry: replication_progress) { client.update_application(PLACE_APP_CLIENT_ID, web.to_json) }
      rescue ex : Office365::Exception
        return nil if already_exists_error?(ex.http_body)
        raise ex
      end
    end

    private def add_outlook_plugin_auth(app_id : String, domain : String) : Nil
      client = get_client
      app = GraphReplicationRetry.run(on_retry: replication_progress) { client.get_application(app_id) }
      app_redirect_uris = app.web.try &.redirect_uris || [] of String
      app_redirect_uris.push("https://#{domain}/outlook/#/book/spaces")

      scope_id = UUID.v4.to_s

      updated = {
        "identifierUris": ["api://#{domain}/#{app_id}"],
        "web":            {
          "redirectUris":          app_redirect_uris,
          "implicitGrantSettings": {"enableAccessTokenIssuance" => true, "enableIdTokenIssuance" => true},
        },
        "api": {
          "oauth2PermissionScopes": [
            {
              "id":                      scope_id,
              "adminConsentDisplayName": "Access User and Room Calendars",
              "adminConsentDescription": "Allow the app to read the user calendar and calendars of rooms the user has permission to view/book.",
              "userConsentDisplayName":  "Access User and Room Calendars",
              "userConsentDescription":  "Allow the app to read the user calendar and calendars of rooms the user has permission to view/book.",
              "isEnabled":               true,
              "type":                    "User",
              "value":                   "access_as_user",
            },
          ],
        },
      }
      GraphReplicationRetry.run(on_retry: replication_progress) { client.update_application(app_id, updated.to_json) }

      updated = {
        "api": {
          "preAuthorizedApplications": [
            {"appId": "d3590ed6-52b3-4102-aeff-aad2292ab01c", "delegatedPermissionIds": [scope_id]}, # Microsoft Office
            {"appId": "ea5a67f6-b6f3-4338-b240-c655ddc3cc8e", "delegatedPermissionIds": [scope_id]}, # Microsoft Office
            {"appId": "57fb890c-0dab-4253-a5e0-7188c88b2bb4", "delegatedPermissionIds": [scope_id]}, # Office on the web
            {"appId": "08e18876-6177-487e-b8b5-cf950c1e598c", "delegatedPermissionIds": [scope_id]}, # Office on the web
            {"appId": "bc59ab01-8403-45c6-8796-ac3ef710b3e3", "delegatedPermissionIds": [scope_id]}, # Outlook on the web
            {"appId": "93d53678-613d-4013-afc1-62e9e444a0a5", "delegatedPermissionIds": [scope_id]}, # Office on the web
          ],
        },
      }
      GraphReplicationRetry.run(on_retry: replication_progress) { client.update_application(app_id, updated.to_json) }
    end

    # Store the visualiser app's app-only Graph credential in the staff-api
    # tenant for this domain - this is what gives PlaceOS calendar access
    # without a signed-in user. The flow owns the domain's Microsoft
    # configuration (like login_url and outlook_config), so an existing
    # tenant is switched to these credentials; delegated mode can be
    # re-enabled afterwards in Backoffice if a customer prefers it.
    def self.upsert_calendar_tenant(domain : String, azure_tenant_id : String, app : NamedTuple(client_id: String, client_secret: String), name : String?) : ::PlaceOS::Model::Tenant
      credentials = {
        tenant:        azure_tenant_id,
        client_id:     app[:client_id],
        client_secret: app[:client_secret],
      }.to_json

      if tenant = ::PlaceOS::Model::Tenant.find_by?(domain: domain)
        tenant.platform = "office365"
        tenant.delegated = false
        tenant.credentials = credentials
        tenant.save!
        tenant
      else
        ::PlaceOS::Model::Tenant.create!(
          name: name,
          domain: domain,
          platform: "office365",
          delegated: false,
          credentials: credentials,
        )
      end
    end

    private def create_outlook_repo : Nil
      return if on_primary { ::PlaceOS::Model::Repository.where(name: "Outlook Plugin", uri: "https://github.com/placeos/user-interfaces", branch: "build/outlook-rooms-addin/prod",
                  folder_name: "outlookplugin", repo_type: ::PlaceOS::Model::Repository::Type::Interface.value).count } > 0

      ::PlaceOS::Model::Repository.create(
        name: "Outlook Plugin", uri: "https://github.com/placeos/user-interfaces", branch: "build/outlook-rooms-addin/prod",
        folder_name: "outlookplugin", repo_type: ::PlaceOS::Model::Repository::Type::Interface
      )
    end

    private def create_outlook_config(app_id : String, domain : String) : Nil
      tenant = ::PlaceOS::Model::Tenant.find_by?(domain: domain)
      unless tenant
        Log.error { {message: "Tenant not found", domain: domain} }
        return
      end

      outlook_config = {
        app_id: app_id, base_path: "outlook", app_domain: "https://#{domain}/outlook/",
        app_resource: "api://#{domain}/#{app_id}", source_location: "",
      }
      tenant.outlook_config = ::PlaceOS::Model::Tenant::OutlookConfig.from_json(outlook_config.to_json)
      tenant.save!
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
