require "placeos-models/group/application_membership"

require "../application"

module PlaceOS::Api
  class Groups::ApplicationMemberships < Application
    base "/api/engine/v2/group_application_memberships/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :destroy]

    # sys_admin only for create / destroy. Index / show are open to any
    # authenticated user — these rows describe which teams are in which
    # subsystems, not secrets.
    before_action :check_admin, only: [:create, :destroy]

    ###############################################################################################

    # Composite PK: a URL path of `:group_id/:application_id`.
    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_membership(group_id : String, application_id : String)
      Log.context.set(group_id: group_id, application_id: application_id)
      @current_membership = ::PlaceOS::Model::GroupApplicationMembership.find!({
        UUID.new(group_id),
        UUID.new(application_id),
      })
    end

    getter! current_membership : ::PlaceOS::Model::GroupApplicationMembership

    @[AC::Route::Filter(:before_action, only: [:create], body: :membership_update)]
    def parse_membership(@membership_update : ::PlaceOS::Model::GroupApplicationMembership)
    end

    getter! membership_update : ::PlaceOS::Model::GroupApplicationMembership

    ###############################################################################################

    # Memberships for the current authority — scoped via the group.
    # Optionally filter by `group_id` or `application_id` query params.
    @[AC::Route::GET("/")]
    def index(
      group_id : String? = nil,
      application_id : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupApplicationMembership)
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      app_ids = ::PlaceOS::Model::GroupApplication
        .where(authority_id: authority_id)
        .to_a
        .map { |a| a.id.as(UUID) }
      return [] of ::PlaceOS::Model::GroupApplicationMembership if app_ids.empty?

      query = ::PlaceOS::Model::GroupApplicationMembership.where(application_id: app_ids)
      query = query.where(group_id: UUID.new(group_id)) if group_id
      query = query.where(application_id: UUID.new(application_id)) if application_id
      paginate_sql(query, type: "group_application_memberships", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:group_id/:application_id")]
    def show : ::PlaceOS::Model::GroupApplicationMembership
      current_membership
    end

    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::GroupApplicationMembership
      membership = membership_update
      membership.acting_user = current_user
      raise Error::ModelValidation.new(membership.errors) unless membership.save
      membership
    end

    @[AC::Route::DELETE("/:group_id/:application_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      membership = current_membership
      membership.acting_user = current_user
      membership.destroy
    end
  end
end
