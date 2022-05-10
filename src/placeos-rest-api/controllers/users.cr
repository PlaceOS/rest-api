require "oauth2"
require "CrystalEmail"

require "./application"
require "./metadata"

module PlaceOS::Api
  class Users < Application
    base "/api/engine/v2/users/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :user, only: [:destroy, :update, :show]

    before_action :check_admin, only: [:index, :destroy, :create]

    # Callbacks
    ###############################################################################################

    before_action :check_authorization, only: [:update, :update_alt]
    before_action :ensure_json, only: [:update, :update_alt]
    before_action :body, only: [:create, :update, :update_alt]

    # Params
    ###############################################################################################

    getter name : String? do
      params["name"]?.presence
    end

    getter emails : Array(String)? do
      params["emails"]?.presence.try &.split(',')
    end

    getter authority_id : String? do
      params["authority_id"]?.presence || params["authority"]?.presence
    end

    getter? include_deleted : Bool do
      boolean_param("include_deleted")
    end

    ###############################################################################################

    getter user : Model::User do
      lookup = params["id"]

      # Index ordering to use for resolving the user.
      ordering = if lookup.is_email?
                   {:email, :login_name}
                 else
                   {:id, :login_name, :staff_id}
                 end

      authority = current_user.authority_id.as(String)

      ordering.each.compact_map do |id_type|
        case id_type
        when :id
          # TODO: Remove user id query prefixing.
          # Remove after June 2023, added to help with 2022 user id migration
          id_lookup = lookup.starts_with?("#{Model::User.table_name}-") ? lookup : "#{Model::User.table_name}-#{lookup}"
          Model::User.find(id_lookup)
        when :email
          Model::User.find_by_email(authority_id: authority, email: lookup)
        when :login_name
          Model::User.find_by_login_name(authority_id: authority, login_name: lookup)
        when :staff_id
          Model::User.find_by_staff_id(authority_id: authority, staff_id: lookup)
        end
      end.first do
        # 404 if the `User` was not found
        raise RethinkORM::Error::DocumentNotFound.new
      end.tap do |user|
        Log.context.set(user_id: user.id)
      end
    end

    ###############################################################################################

    # Render the current user
    get("/current", :current) do
      render_json do |json|
        current_user.to_admin_json(json)
      end
    rescue e : RethinkORM::Error::DocumentNotFound
      head :unauthorized
    end

    # Obtain a token to the current users SSO resource
    post("/resource_token", :resource_token) do
      expired = true

      if access_token = current_user.access_token.presence
        if current_user.expires
          expires_at = Time.unix(current_user.expires_at.not_nil!)
          if 5.minutes.from_now < expires_at
            render json: {
              token:   access_token,
              expires: expires_at.to_unix,
            }
          end

          # Allow for clock drift
          expired = 15.seconds.from_now > expires_at
        else
          render json: {token: access_token}
        end
      end

      head :not_found unless current_user.refresh_token.presence
      authority = current_authority
      head :not_found unless authority

      begin
        internals = authority.internals
        sso_strat = if sso_strat_id = internals["oauth-strategy"]?.try(&.as_s?) # (i.e. oauth_strat-FNsaSj6bp-M)
                      ::PlaceOS::Model::OAuthAuthentication.find(sso_strat_id)
                    else
                      ::PlaceOS::Model::OAuthAuthentication.collection_query do |table|
                        table.get_all(authority.id, index: :authority_id)
                      end.first?
                    end
        render(:not_found, text: "no oauth configuration found") unless sso_strat

        client_id = sso_strat.client_id
        client_secret = sso_strat.client_secret
        token_uri = URI.parse(sso_strat.token_url)
        token_host = token_uri.hostname.not_nil!
        token_path = token_uri.request_target

        oauth2_client = OAuth2::Client.new(token_host, client_id, client_secret, token_uri: token_path)
        token = oauth2_client.get_access_token_using_refresh_token(current_user.refresh_token, sso_strat.scope)

        current_user.access_token = token.access_token
        current_user.refresh_token = token.refresh_token if token.refresh_token
        current_user.expires_at = Time.utc.to_unix + token.expires_in.not_nil!
        current_user.save!

        render json: {
          token:   current_user.access_token,
          expires: current_user.expires_at,
        }
      rescue error
        Log.warn(exception: error) { "failed refresh access token" }
        if !expired
          render json: {
            token:   current_user.access_token,
            expires: current_user.expires_at,
          }
        else
          raise error
        end
      end
    end

    # CRUD
    ###############################################################################################

    def index
      elastic = Model::User.elastic
      params["q"] = %("#{params["q"]}") if params["q"]?.to_s.is_email?
      query = elastic.query(params)

      query.must_not({"deleted" => [true]}) unless include_deleted?

      if authority = authority_id
        query.filter({"authority_id" => [authority]})
      end

      render_json do |json|
        json.array do
          paginate_results(elastic, query).each &.to_admin_json(json)
        end
      end
    end

    def show
      # We only want to provide limited "public" information
      render_json do |json|
        is_admin? ? user.to_admin_json(json) : user.to_public_json(json)
      end
    end

    def create
      body = self.body.gets_to_end
      new_user = Model::User.from_json(body)
      new_user.assign_admin_attributes_from_json(body)

      # allow sys-admins to create users on other domains
      new_user.authority ||= current_authority.as(Model::Authority)

      save_and_respond new_user
    end

    def update
      # Allow additional attributes to be applied by admins
      # (the users themselves should not have access to these)
      # TODO:: Use scopes.
      body = self.body.gets_to_end
      if is_admin?
        user.assign_admin_attributes_from_json(body)
      end
      user.assign_attributes_from_json(body)

      save_and_respond user
    end

    put_redirect

    # Destroy user, revoke authentication.
    def destroy
      if current_authority.try &.internals["soft_delete"]? == true
        user.deleted = true
        user.save
      else
        user.destroy
      end
      head :ok
    rescue e : Model::Error
      render_error(HTTP::Status::BAD_REQUEST, e.message)
    end

    ###############################################################################################

    get "/:id/metadata", :metadata do
      parent_id = user.id.not_nil!
      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    # # Params
    # - `emails`: comma-seperated list of emails *required*
    # # Returns
    # - `[{id: "<user-id>", groups: ["<group>"]}]`
    get("/groups", :groups) do
      emails_param = required_param(emails)

      unless (errors = self.class.validate_emails(emails_param)).empty?
        return render_error(HTTP::Status::UNPROCESSABLE_ENTITY, errors.join(", "))
      end

      render_json do |json|
        json.array do
          Model::User
            .find_by_emails(authority_id: current_user.authority_id.as(String), emails: emails_param)
            .each &.to_group_json(json)
        end
      end
    end

    def self.validate_emails(emails) : Array(String)
      emails.each_with_object([] of String) do |email, errors|
        errors << "#{email} is an invalid email" unless email.is_email?
      end
    end

    # Helpers
    ###############################################################################################

    protected def check_authorization
      # Does the current user have permission to perform the current action
      head :forbidden unless user.id == current_user.id || is_admin?
    end
  end
end
