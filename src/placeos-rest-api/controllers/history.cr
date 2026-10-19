require "placeos-models/history"

require "./application"

module PlaceOS::Api
  # Change history of the platform's models, see `PlaceOS::Model::History`
  class History < Application
    base "/api/engine/v2/history/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:undelete]

    before_action :check_admin

    ###############################################################################################

    # Restores the latest deleted version of a record, nil if `resource_type`
    # has no change history
    def self.undelete(resource_type : String, resource_id : String) : ::PgORM::Base?
      {% begin %}
        case resource_type
        {% for model in ::PlaceOS::Model::History::Tracked.includers %}
          when {{ model }}.table_name then {{ model }}.undelete(resource_id)
        {% end %}
        end
      {% end %}
    end

    @[AC::Route::Filter(:before_action, only: [:show])]
    def find_current_history(id : UUID)
      Log.context.set(history_id: id.to_s)
      @current_history = ::PlaceOS::Model::History.find!(id)
    end

    getter! current_history : ::PlaceOS::Model::History

    ###############################################################################################

    # List changes, newest first
    @[AC::Route::GET("/", converters: {resource_types: ConvertStringArray, exclude_resource_types: ConvertStringArray, actions: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "only return changes to these resource types (table names)", example: "zone,sys")]
      resource_types : Array(String)? = nil,
      @[AC::Param::Info(description: "exclude changes to these resource types (table names)", example: "bookings,event_metadatas")]
      exclude_resource_types : Array(String)? = nil,
      @[AC::Param::Info(description: "only return changes to this resource, usually combined with `resource_types`", example: "zone-1234")]
      resource_id : String? = nil,
      @[AC::Param::Info(description: "only return changes related to this parent, such as a group, playlist or booking", example: "0192d1c8-2f0e-7cc1-9d2a-6f1c7e1b3a51")]
      correlation_id : String? = nil,
      @[AC::Param::Info(description: "only return changes made by this user", example: "user-1234")]
      user_id : String? = nil,
      @[AC::Param::Info(description: "only return these kinds of change: create, update, delete, approve or restore", example: "delete")]
      actions : Array(String)? = nil,
      @[AC::Param::Info(description: "only return changes made at or after this time, as a unix epoch", example: "1729382400")]
      period_start : Int64? = nil,
      @[AC::Param::Info(description: "only return changes made before this time, as a unix epoch", example: "1729468800")]
      period_end : Int64? = nil,
      @[AC::Param::Info(description: "the maximum number of results to return", example: "100")]
      limit : Int32 = 100,
      @[AC::Param::Info(description: "the starting offset of the result set, used to implement pagination")]
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::History)
      query = ::PlaceOS::Model::History.order(created_at: :desc, id: :desc)
      query = query.where(resource_type: resource_types) if resource_types && !resource_types.empty?
      query = query.where_not(resource_type: exclude_resource_types) if exclude_resource_types && !exclude_resource_types.empty?
      query = query.where(resource_id: resource_id) if resource_id
      query = query.where(correlation_id: correlation_id) if correlation_id
      query = query.where(user_id: user_id) if user_id
      query = query.where(action: actions) if actions && !actions.empty?
      query = query.where("created_at >= ?", Time.unix(period_start)) if period_start
      query = query.where("created_at < ?", Time.unix(period_end)) if period_end

      paginate_sql(query, type: "history", limit: limit.clamp(0, 10_000), offset: offset.clamp(0, 1_000_000))
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::History
      current_history
    end

    # Restores a deleted record from its change history, keeping its id.
    # Records deleted alongside it are not restored and redacted fields, such
    # as passwords and secrets, are left empty.
    @[AC::Route::POST("/undelete", status_code: HTTP::Status::CREATED)]
    def undelete(
      @[AC::Param::Info(description: "the type (table name) of the deleted resource", example: "zone")]
      resource_type : String,
      @[AC::Param::Info(description: "the id of the deleted resource", example: "zone-1234")]
      resource_id : String,
    ) : ::PgORM::Base
      begin
        self.class.undelete(resource_type, resource_id) || raise Error::NotFound.new("#{resource_type} has no change history")
      rescue error : ::PgORM::Error::RecordNotFound
        raise error
      rescue error : ::PgORM::Error
        # i.e. the record already exists or now clashes with another
        raise Error::Conflict.new("#{resource_type} #{resource_id} could not be restored: #{error.message}")
      end
    end
  end
end
