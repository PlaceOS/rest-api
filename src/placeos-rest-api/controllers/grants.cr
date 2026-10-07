require "placeos-models/grant"

require "./application"

module PlaceOS::Api
  # Grants: explicit, revocable, optionally time-boxed reach for a user into a
  # partner, organisation or domain they do not belong to (PPT-526)
  class Grants < Application
    base "/api/engine/v2/grants/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :destroy]

    before_action :check_admin

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_grant(id : UUID)
      Log.context.set(grant_id: id.to_s)
      grant = ::PlaceOS::Model::Grant.find!(id)
      ensure_scope_reach!(grant.scope_type, grant.scope_id)
      @current_grant = grant
    end

    getter! current_grant : ::PlaceOS::Model::Grant

    # Cluster admins manage every scope; organisation admins manage grants
    # into their own organisation and its domains; partner admins request
    # rather than self-grant
    protected def ensure_scope_reach!(scope_type : String, scope_id : String) : Nil
      return if tenancy.cluster?
      own = tenancy.organisation_id
      allowed = case scope_type
                when ::PlaceOS::Model::Grant::SCOPE_ORGANISATION
                  own && own.to_s == scope_id
                when ::PlaceOS::Model::Grant::SCOPE_AUTHORITY
                  own && ::PlaceOS::Model::Authority.find?(scope_id).try(&.organisation_id) == own
                else
                  false
                end
      return if allowed
      log_would_refuse("grant scope outside reach")
      raise Error::Forbidden.new if Utils::Tenancy.enforce?
    end

    ###############################################################################################

    # grants on a scope, or held by a user
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "partner, organisation or authority", example: "organisation")]
      scope_type : String? = nil,
      @[AC::Param::Info(description: "the id of the partner, organisation or domain", example: "0192f1c4-7a6b-7c4d-9f3e-1a2b3c4d5e6f")]
      scope_id : String? = nil,
      @[AC::Param::Info(description: "grants held by this user", example: "user-1234")]
      user_id : String? = nil,
    ) : Array(::PlaceOS::Model::Grant)
      query = ::PlaceOS::Model::Grant.all
      if scope_type && scope_id
        ensure_scope_reach!(scope_type, scope_id)
        query = query.where(scope_type: scope_type, scope_id: scope_id)
      elsif user_id
        ensure_authority_reach!(::PlaceOS::Model::User.find!(user_id).authority_id, "user")
        query = query.where(user_id: user_id)
      else
        check_cluster_admin
      end
      paginate_sql(query.order("created_at, id"), ::PlaceOS::Model::Grant.table_name, limit: search_limit, offset: search_offset)
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Grant
      current_grant
    end

    record GrantBody, user_id : String, scope_type : String, scope_id : String, permissions : Int32 = 1, expires_at : Time? = nil do
      include JSON::Serializable
    end

    @[AC::Route::POST("/", body: :body, status_code: HTTP::Status::CREATED)]
    def create(body : GrantBody) : ::PlaceOS::Model::Grant
      ensure_scope_reach!(body.scope_type, body.scope_id)
      ::PlaceOS::Model::User.find!(body.user_id)
      grant = ::PlaceOS::Model::Grant.new(
        user_id: body.user_id,
        scope_type: body.scope_type,
        scope_id: body.scope_id,
        permissions: body.permissions,
        expires_at: body.expires_at,
        granted_by: current_user.id,
      )
      raise Error::ModelValidation.new(grant.errors) unless grant.save
      grant
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_grant.destroy
    end
  end
end
