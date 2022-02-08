require "oauth2"
require "CrystalEmail"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

require "./application"
require "./metadata"

module PlaceOS::Api
  class Users < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController

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

    getter user : Model::User { find_user }

    # Render the current user
    get("/current", :current, annotations: @[OpenAPI(<<-YAML
    summary: Render the current user
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
      401:
        description: OK
    YAML
    )]) do
      # get("/current", :current) do
      render_json do |json|
        current_user.to_admin_json(json)
      end
    rescue e : RethinkORM::Error::DocumentNotFound
      head :unauthorized
    end

    # Obtain a token to the current users SSO resource
    # post("/resource_token", :resource_token) do

    # post("/resource_token", :resource_token, annotations: @[OpenAPI(<<-YAML
    # summary: Get a token to the current users SSO resource
    # security:
    # - bearerAuth: []
    # responses:
    #   200:
    #     description: OK
    #   404:
    #     description: OK
    # YAML
    # )]) do
    #   expired = true

    #   if access_token = current_user.access_token.presence
    #     if current_user.expires
    #       expires_at = Time.unix(current_user.expires_at.not_nil!)
    #       if 5.minutes.from_now < expires_at
    #         render json: {
    #           token:   access_token,
    #           expires: expires_at.to_unix,
    #         }
    #       end

    #       # Allow for clock drift
    #       expired = 15.seconds.from_now > expires_at
    #     else
    #       render json: {token: access_token}
    #     end
    #   end

    #   head :not_found unless current_user.refresh_token.presence

    #   begin
    #     internals = current_authority.not_nil!.internals
    #     sso_strat_id = internals["oauth-strategy"].as_s # (i.e. oauth_strat-FNsaSj6bp-M)
    #     render(:not_found, text: "no oauth configuration specified in authority") unless sso_strat_id.presence

    #     sso_strat = ::PlaceOS::Model::OAuthAuthentication.find!(sso_strat_id)
    #     client_id = sso_strat.client_id
    #     client_secret = sso_strat.client_secret
    #     token_uri = URI.parse(sso_strat.token_url)
    #     token_host = token_uri.hostname.not_nil!
    #     token_path = token_uri.request_target

    #     oauth2_client = OAuth2::Client.new(token_host, client_id, client_secret, token_uri: token_path)
    #     token = oauth2_client.get_access_token_using_refresh_token(current_user.refresh_token, sso_strat.scope)

    #     current_user.access_token = token.access_token
    #     current_user.refresh_token = token.refresh_token if token.refresh_token
    #     current_user.expires_at = Time.utc.to_unix + token.expires_in.not_nil!
    #     current_user.save!

    #     render json: {
    #       token:   current_user.access_token,
    #       expires: current_user.expires_at,
    #     }
    #   rescue error
    #     Log.warn(exception: error) { "failed refresh access token" }
    #     if !expired
    #       render json: {
    #         token:   current_user.access_token,
    #         expires: current_user.expires_at,
    #       }
    #     else
    #       raise error
    #     end
    #   end
    # end

    # CRUD
    ###############################################################################################

    @[OpenAPI(
      <<-YAML
        summary: get all users
        parameters:
          #{Schema.qp "authority_id", "....", type: "string"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array User}
      YAML
    )]
    def index
      elastic = Model::User.elastic
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

    @[OpenAPI(
      <<-YAML
        summary: get users
        parameters:
          #{Schema.qp "authority_id", "....", type: "string"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def show
      # We only want to provide limited "public" information
      render_json do |json|
        is_admin? ? user.to_admin_json(json) : user.to_public_json(json)
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Create a zone
        requestBody:
          required: true
          content:
            #{Schema.ref Model::User}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Model::User}
      YAML
    )]
    def create
      body = self.body.gets_to_end
      new_user = Model::User.from_json(body)
      new_user.assign_admin_attributes_from_json(body)

      # allow sys-admins to create users on other domains
      new_user.authority ||= current_authority.as(Model::Authority)

      save_and_respond new_user
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a user
        requestBody:
          required: true
          content:
            #{Schema.ref Model::User}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::User}
      YAML
    )]
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

    # TODO: replace manual id with interpolated value from `id_param`
    # put "/:id", :update_alt { update }

    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
    summary: Update a user
    requestBody:
      required: true
      content:
        #{Schema.ref Model::User}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Model::User}
  YAML
    )]) { update }

    # Destroy user, revoke authentication.
    @[OpenAPI(
      <<-YAML
        summary: Delete a user
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
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

    # get "/:id/metadata", :metadata do
    get("/:id/metadata", :metadata, annotations: @[OpenAPI(<<-YAML
    summary: Get the metadata of a user
    parameters:
      #{Schema.qp "name", "The name of the metadata", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref Model::Open_Metadata}
    YAML
    )]) do
      parent_id = user.id.not_nil!
      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    # # Params
    # - `emails`: comma-seperated list of emails *required*
    # # Returns
    # - `[{id: "<user-id>", groups: ["<group>"]}]`
    get("/groups", :groups, annotations: @[OpenAPI(<<-YAML
    summary: Get list of groups of users based on email
    parameters:
      #{Schema.qp "emails", " comma-seperated list of emails", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
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

    protected def find_user
      lookup = params["id"]

      # Index ordering to use for resolving the user.
      ordering = if lookup.is_email?
                   {:email, :login_name}
                 else
                   {:id, :login_name, :staff_id}
                 end

      authority = current_user.authority_id.as(String)

      query = ordering.each.compact_map do |id_type|
        case id_type
        when :id
          Model::User.find(lookup)
        when :email
          Model::User.find_by_email(authority_id: authority, email: lookup)
        when :login_name
          Model::User.find_by_login_name(authority_id: authority, login_name: lookup)
        when :staff_id
          Model::User.find_by_staff_id(authority_id: authority, staff_id: lookup)
        end
      end

      user = query.first { raise RethinkORM::Error::DocumentNotFound.new }

      Log.context.set(user_id: user.id)
      user
    end

    protected def check_authorization
      # Does the current user have permission to perform the current action
      head :forbidden unless user.id == current_user.id || is_admin?
    end
  end
end
