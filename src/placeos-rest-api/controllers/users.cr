require "oauth2"

require "./application"

module PlaceOS::Api
  class Users < Application
    include Utils::CurrentUser

    base "/api/engine/v2/users/"

    before_action :find_user, only: [:destroy, :update, :show]
    before_action :check_admin, only: [:index, :destroy, :create]
    before_action :check_authorization, only: [:update, :update_alt]

    before_action :ensure_json, only: [:update, :update_alt]

    getter user : Model::User?

    # Render the current user
    get("/current", :current) do
      begin
        render json: current_user.as_admin_json
      rescue e : RethinkORM::Error::DocumentNotFound
        head :unauthorized
      end
    end

    # Obtain a token to the current users SSO resource
    post("/resource_token", :resource_token) do
      user = current_user
      expired = true

      if access_token = user.access_token.presence
        if user.expires
          expires_at = Time.unix(user.expires_at.not_nil!)
          if expires_at > 5.minutes.from_now
            render json: {
              token:   access_token,
              expires: expires_at.to_unix,
            }
          end

          # Allow for clock drift
          expired = expires_at <= 15.seconds.ago
        else
          render json: {token: access_token}
        end
      end

      head :not_found unless user.refresh_token.presence

      begin
        internals = current_authority.not_nil!.internals.not_nil!
        sso_strat_id = internals["oauth-strategy"].as_s # (i.e. oauth_strat-FNsaSj6bp-M)
        render(:not_found, text: "no oauth configuration specified in authority") unless sso_strat_id.presence

        sso_strat = ::PlaceOS::Model::OAuthAuthentication.find!(sso_strat_id.not_nil!)
        client_id = sso_strat.client_id.not_nil!
        client_secret = sso_strat.client_secret.not_nil!
        token_uri = URI.parse(sso_strat.token_url.not_nil!)
        token_host = token_uri.host.not_nil!
        token_path = token_uri.full_path

        oauth2_client = OAuth2::Client.new(token_host, client_id, client_secret, token_uri: token_path)
        token = oauth2_client.get_access_token_using_refresh_token(user.refresh_token.not_nil!, sso_strat.scope)

        user.access_token = token.access_token
        user.refresh_token = token.refresh_token if token.refresh_token
        user.expires_at = Time.utc.to_unix + token.expires_in.not_nil!
        user.save!

        render json: {
          token:   user.access_token,
          expires: user.expires_at,
        }
      rescue error
        Log.warn(exception: error) { "failed refresh access token" }
        if !expired
          render json: {
            token:   user.access_token,
            expires: user.expires_at,
          }
        else
          raise error
        end
      end
    end

    def index
      elastic = Model::User.elastic
      query = elastic.query(params)

      query.must_not({"deleted" => [true]})

      authority_id = params["authority_id"]?
      query.filter({"authority_id" => [authority_id]}) if authority_id

      results = paginate_results(elastic, query).map &.as_admin_json
      render json: results
    end

    def show
      # We only want to provide limited "public" information
      if is_admin?
        render json: @user.try &.as_admin_json
      else
        render json: @user.try &.as_public_json
      end
    end

    def create
      user = Model::User.from_json(request.body.as(IO))
      # allow sys-admins to create users on other domains
      user.authority ||= current_authority.as(Model::Authority)

      save_and_respond user
    end

    struct AdminAttributes
      include JSON::Serializable

      getter login_name : String?
      getter staff_id : String?
      getter card_number : String?
      getter groups : Array(String)?
    end

    def update
      user = @user.as(Model::User)
      body = request.body.as(IO).gets_to_end

      # Allow additional attributes to be applied by admins
      # (the users themselves should not have access to these)
      # TODO:: probably should be using scopes for this
      if is_admin?
        attrs = AdminAttributes.from_json(body)
        user.login_name = attrs.login_name if attrs.login_name
        user.staff_id = attrs.staff_id if attrs.staff_id
        user.card_number = attrs.card_number if attrs.card_number
        user.groups = attrs.groups.as(Array(String)) if attrs.groups
      end

      # Ensure authority doesn't change
      authority_id = user.authority_id
      user.assign_attributes_from_json(body)
      user.authority_id = authority_id

      save_and_respond user
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    # Destroy user, revoke authentication.
    def destroy
      @user.try &.destroy
      head :ok
    end

    protected def find_user
      id = params["id"]
      Log.context.set(user_id: id)

      user || (@user = Model::User.find!(id, runopts: {"read_mode" => "majority"}))
    end

    protected def check_authorization
      # Does the current user have permission to perform the current action
      head :forbidden unless (find_user.try &.id) == current_user.id || is_admin?
    end
  end
end
