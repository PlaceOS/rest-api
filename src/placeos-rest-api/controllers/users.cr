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
    before_action :can_write, only: [:create, :update, :destroy, :remove, :revive]

    before_action :user, only: [:destroy, :update, :revive, :show, :delete_resource_token]

    before_action :check_admin, only: [:destroy, :create, :revive, :delete_resource_token]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :current, :resource_token, :groups])]
    def find_user(
      @[AC::Param::Info(name: "id", description: "the id of the user", example: "user-1234")]
      lookup : String
    )
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

    getter! user : Model::User

    # Check the user has access to the model
    @[AC::Route::Filter(:before_action, only: [:update])]
    protected def check_authorization
      # Does the current user have permission to perform the current action
      raise Error::Forbidden.new unless user.id == current_user.id || is_admin?
    end

    ###############################################################################################

    # Render the current user
    @[AC::Route::GET("/current")]
    def current : Model::User::AdminResponse
      current_user.to_admin_struct
    rescue e : RethinkORM::Error::DocumentNotFound
      raise Error::Unauthorized.new("user not found")
    end

    record AccessToken, token : String, expires : Int64? { include JSON::Serializable }

    # Obtain a token to the current users SSO resource
    @[AC::Route::POST("/resource_token")]
    def resource_token : AccessToken
      expired = true

      if access_token = current_user.access_token.presence
        if current_user.expires
          expires_at = Time.unix(current_user.expires_at.not_nil!)
          if 5.minutes.from_now < expires_at
            return AccessToken.new(access_token.as(String), expires_at.to_unix)
          end

          # Allow for clock drift
          expired = 15.seconds.from_now > expires_at
        else
          return AccessToken.new(access_token.as(String), nil)
        end
      end

      raise Error::NotFound.new("no refresh token available") unless current_user.refresh_token.presence
      authority = current_authority
      raise Error::NotFound.new("no valid authority") unless authority

      begin
        internals = authority.internals
        sso_strat = if sso_strat_id = internals["oauth-strategy"]?.try(&.as_s?) # (i.e. oauth_strat-FNsaSj6bp-M)
                      ::PlaceOS::Model::OAuthAuthentication.find(sso_strat_id)
                    else
                      ::PlaceOS::Model::OAuthAuthentication.collection_query do |table|
                        table.get_all(authority.id, index: :authority_id)
                      end.first?
                    end

        raise Error::NotFound.new("no oauth configuration found") unless sso_strat

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

        AccessToken.new(current_user.access_token.as(String), current_user.expires_at)
      rescue error
        Log.warn(exception: error) { "failed refresh access token" }
        if !expired
          AccessToken.new(current_user.access_token.as(String), current_user.expires_at)
        else
          raise error
        end
      end
    end

    @[AC::Route::DELETE("/:id/resource_token", status_code: HTTP::Status::ACCEPTED)]
    def delete_resource_token : Nil
      user.access_token = nil
      user.refresh_token = nil
      user.expires_at = nil
      user.expires = false
      user.save!
    end

    # CRUD
    ###############################################################################################

    @[AC::Route::GET("/")]
    def index(
      include_deleted : Bool = false,
      include_metadata : Bool = false,
      @[AC::Param::Info(description: "admin users can view other domains, ignored for other users", example: "auth-12345")]
      authority_id : String? = nil
    ) : Array(PlaceOS::Model::User::AdminMetadataResponse) | Array(PlaceOS::Model::User::AdminResponse) | Array(PlaceOS::Model::User::PublicMetadataResponse) | Array(PlaceOS::Model::User::PublicResponse)
      elastic = Model::User.elastic
      search_query = search_params
      search_query["q"] = %("#{search_query["q"]}") if search_query["q"]?.to_s.is_email?
      query = elastic.query(search_query)
      query.sort(NAME_SORT_ASC)

      query.must_not({"deleted" => [true]}) unless include_deleted

      if !is_admin?
        # regular users can only see their own domain
        query.filter({"authority_id" => [current_user.authority_id.as(String)]})
      elsif authority = authority_id
        query.filter({"authority_id" => [authority]})
      end

      if is_admin?
        if include_metadata
          paginate_results(elastic, query).map &.to_admin_metadata_struct
        else
          paginate_results(elastic, query).map &.to_admin_struct
        end
      else
        if include_metadata
          paginate_results(elastic, query).map &.to_public_metadata_struct
        else
          paginate_results(elastic, query).map &.to_public_struct
        end
      end
    end

    @[AC::Route::GET("/:id")]
    def show(
      include_metadata : Bool = false
    ) : Model::User::AdminResponse | Model::User::PublicResponse | Model::User::AdminMetadataResponse | Model::User::PublicMetadataResponse
      # We only want to provide limited "public" information
      if is_admin?
        include_metadata ? user.to_admin_metadata_struct : user.to_admin_struct
      else
        include_metadata ? user.to_public_metadata_struct : user.to_public_struct
      end
    end

    @[AC::Route::POST("/", body: :new_user, status_code: HTTP::Status::CREATED)]
    def create(new_user : JSON::Any) : Model::User
      body = new_user.to_json
      new_user = Model::User.from_json(body)
      new_user.assign_admin_attributes_from_json(body)

      # allow sys-admins to create users on other domains
      new_user.authority ||= current_authority.as(Model::Authority)

      raise Error::ModelValidation.new(new_user.errors) unless new_user.save
      new_user
    end

    @[AC::Route::PATCH("/:id", body: :new_user)]
    @[AC::Route::PUT("/:id", body: :new_user)]
    def update(new_user : JSON::Any) : Model::User
      # Allow additional attributes to be applied by admins
      # (the users themselves should not have access to these)
      body = new_user.to_json
      the_user = user
      if is_admin?
        the_user.assign_admin_attributes_from_json(body)
      end
      the_user.assign_attributes_from_json(body)

      raise Error::ModelValidation.new(the_user.errors) unless the_user.save
      the_user
    end

    # Destroy user, revoke authentication.
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      force_removal : Bool = false
    ) : Nil
      if !force_removal && current_authority.try &.internals["soft_delete"]? == true
        user.deleted = true
        raise Error::ModelValidation.new(user.errors) unless user.save
      else
        user_id = user.id
        user.destroy
        spawn { Api::Metadata.signal_metadata(:destroy_all, {parent_id: user_id}) }
      end
    end

    @[AC::Route::POST("/:id/revive")]
    def revive
      user.deleted = false
      raise Error::ModelValidation.new(user.errors) unless user.save
    end

    ###############################################################################################

    @[AC::Route::GET("/:id/metadata")]
    def metadata(
      name : String? = nil
    ) : Hash(String, PlaceOS::Model::Metadata::Interface)
      parent_id = user.id.not_nil!
      Model::Metadata.build_metadata(parent_id, name)
    end

    # # Params
    # - `emails`: comma-seperated list of emails *required*
    # # Returns
    # - `[{id: "<user-id>", groups: ["<group>"]}]`
    @[AC::Route::GET("/groups", converters: {emails: ConvertStringArray})]
    def groups(
      emails : Array(String)
    ) : Array(Model::User::GroupResponse)
      unless (errors = self.class.validate_emails(emails)).empty?
        raise Error::ModelValidation.new(errors, "not all provided emails were valid")
      end

      Model::User
        .find_by_emails(authority_id: current_user.authority_id.as(String), emails: emails)
        .map &.to_group_struct
    end

    def self.validate_emails(emails) : Array(Error::Field)
      emails.each_with_object([] of Error::Field) do |email, errors|
        errors << Error::Field.new(:emails, "#{email} is an invalid email") unless email.is_email?
      end
    end
  end
end
