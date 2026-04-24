require "placeos-models/group/doorkeeper"

require "../application"

module PlaceOS::Api
  class Groups::ApplicationDoorkeepers < Application
    base "/api/engine/v2/group_application_doorkeepers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :destroy]

    # OAuth client wiring is sys_admin-only across the board.
    before_action :check_admin

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_link(group_application_id : String, doorkeeper_application_id : Int64)
      Log.context.set(
        group_application_id: group_application_id,
        doorkeeper_application_id: doorkeeper_application_id,
      )
      @current_link = ::PlaceOS::Model::GroupApplicationDoorkeeper.find!({
        UUID.new(group_application_id),
        doorkeeper_application_id,
      })
    end

    getter! current_link : ::PlaceOS::Model::GroupApplicationDoorkeeper

    @[AC::Route::Filter(:before_action, only: [:create], body: :link_update)]
    def parse_link(@link_update : ::PlaceOS::Model::GroupApplicationDoorkeeper)
    end

    getter! link_update : ::PlaceOS::Model::GroupApplicationDoorkeeper

    ###############################################################################################

    @[AC::Route::GET("/")]
    def index(
      group_application_id : String? = nil,
      doorkeeper_application_id : Int64? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupApplicationDoorkeeper)
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      app_ids = ::PlaceOS::Model::GroupApplication
        .where(authority_id: authority_id)
        .to_a
        .map { |a| a.id.as(UUID) }
      return [] of ::PlaceOS::Model::GroupApplicationDoorkeeper if app_ids.empty?

      query = ::PlaceOS::Model::GroupApplicationDoorkeeper.where(group_application_id: app_ids)
      query = query.where(group_application_id: UUID.new(group_application_id)) if group_application_id
      query = query.where(doorkeeper_application_id: doorkeeper_application_id) if doorkeeper_application_id
      paginate_sql(query, type: "group_application_doorkeepers", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:group_application_id/:doorkeeper_application_id")]
    def show : ::PlaceOS::Model::GroupApplicationDoorkeeper
      current_link
    end

    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::GroupApplicationDoorkeeper
      link = link_update
      link.acting_user = current_user
      raise Error::ModelValidation.new(link.errors) unless link.save
      link
    end

    @[AC::Route::DELETE("/:group_application_id/:doorkeeper_application_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      link = current_link
      link.acting_user = current_user
      link.destroy
    end
  end
end
