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

    # Trusted snapshots bypass controller parsers, so restoring them must
    # validate references and delegated credential rights explicitly.
    private def ensure_restore_snapshot!(entry : ::PlaceOS::Model::History)
      fields = entry.snapshot.try(&.as_h?) || raise Error::NotFound.new("deleted snapshot not found")
      type = entry.resource_type
      if type.in?({"partners", "organisations", "driver", "repository"})
        check_cluster_admin
      end
      if authority = fields["authority_id"]?.try(&.as_s?)
        ensure_authority_reach!(authority, "authority", required: ::PlaceOS::Model::Permissions::Read)
        if type.in?({"user", "api_key", "ldap_strat", "adfs_strat", "oauth_strat", "groups"})
          ensure_credential_management!(authority)
        end
      end
      if type == "authority"
        organisation_id = fields["organisation_id"]?.try(&.as_s?).try { |id| UUID.parse?(id) }
        ensure_reach!(organisation_id, "authority", required: ::PlaceOS::Model::Permissions::Manage)
        organisation = organisation_id.try { |id| ::PlaceOS::Model::Organisation.find?(id) }
        if organisation.try(&.partner_staff) && !tenancy_policy.structural?(organisation_id)
          raise Error::Forbidden.new("staff credential management requires structural access")
        end
      end
      if owner = fields["owner_id"]?.try(&.as_s?)
        ensure_authority_reach!(owner, "owner", required: ::PlaceOS::Model::Permissions::Read)
        ensure_credential_management!(owner)
      end
      if type == "grants"
        scope_type = fields["scope_type"]?.try(&.as_s?)
        scope_id = fields["scope_id"]?.try(&.as_s?)
        case scope_type
        when "organisation"
          ensure_reach!(scope_id.try { |id| UUID.parse?(id) }, "grant scope", required: ::PlaceOS::Model::Permissions::Manage)
        when "authority"
          ensure_credential_management!(scope_id)
        else
          check_cluster_admin
        end
      end
      if parent = fields["parent_id"]?.try(&.as_s?).try(&.presence)
        case type
        when "zone"   then ensure_reach!(::PlaceOS::Model::Zone.find!(parent), required: ::PlaceOS::Model::Permissions::Read)
        when "groups" then ensure_authority_reach!(::PlaceOS::Model::Group.find!(UUID.new(parent)).authority_id, "group", required: ::PlaceOS::Model::Permissions::Read)
        when "asset"  then ensure_authority_reach!(::PlaceOS::Model::Asset.find!(parent).asset_type.try(&.category).try(&.authority_id), "asset", required: ::PlaceOS::Model::Permissions::Read)
        end
      end
      {"zones", "modules"}.each do |name|
        fields[name]?.try(&.as_a?).try &.each do |value|
          if name == "zones"
            ensure_reach!(::PlaceOS::Model::Zone.find!(value.as_s), required: ::PlaceOS::Model::Permissions::Read)
          else
            ensure_reach!(::PlaceOS::Model::Module.find!(value.as_s), required: ::PlaceOS::Model::Permissions::Read)
          end
        end
      end
      if id = fields["control_system_id"]?.try(&.as_s?).try(&.presence)
        required = type == "trig" ? ::PlaceOS::Model::Permissions::Manage : ::PlaceOS::Model::Permissions::Read
        ensure_reach!(::PlaceOS::Model::ControlSystem.find!(id), required: required)
      end
      if id = fields["zone_id"]?.try(&.as_s?).try(&.presence)
        ensure_reach!(::PlaceOS::Model::Zone.find!(id), required: ::PlaceOS::Model::Permissions::Read)
      end
      if id = fields["trigger_id"]?.try(&.as_s?).try(&.presence)
        trigger = ::PlaceOS::Model::Trigger.find!(id)
        ensure_reach!(trigger, required: ::PlaceOS::Model::Permissions::Read) if trigger.control_system_id
      end
      if id = fields["group_id"]?.try(&.as_s?)
        authority = ::PlaceOS::Model::Group.find!(UUID.new(id)).authority_id
        ensure_authority_reach!(authority, "group", required: ::PlaceOS::Model::Permissions::Read)
        ensure_credential_management!(authority)
      end
      if id = fields["playlist_id"]?.try(&.as_s?)
        ensure_authority_reach!(::PlaceOS::Model::Playlist.find!(id).authority_id, "playlist", required: ::PlaceOS::Model::Permissions::Read)
      end
      if id = fields["category_id"]?.try(&.as_s?)
        ensure_authority_reach!(::PlaceOS::Model::AssetCategory.find!(id).authority_id, "category", required: ::PlaceOS::Model::Permissions::Read)
      end
      if id = fields["asset_type_id"]?.try(&.as_s?)
        ensure_authority_reach!(::PlaceOS::Model::AssetType.find!(id).category.try(&.authority_id), "asset type", required: ::PlaceOS::Model::Permissions::Read)
      end
      if id = fields["purchase_order_id"]?.try(&.as_s?)
        ensure_authority_reach!(::PlaceOS::Model::AssetPurchaseOrder.find!(id).authority_id, "purchase order", required: ::PlaceOS::Model::Permissions::Read)
      end
      if id = fields["alert_dashboard_id"]?.try(&.as_s?)
        ensure_authority_reach!(::PlaceOS::Model::AlertDashboard.find!(id).authority_id, "dashboard", required: ::PlaceOS::Model::Permissions::Read)
      end
      {"item_id", "background_item_id"}.each do |name|
        if id = fields[name]?.try(&.as_s?)
          ensure_authority_reach!(::PlaceOS::Model::Playlist::Item.find!(id).authority_id, "media", required: ::PlaceOS::Model::Permissions::Read)
        end
      end
      {"media_id", "thumbnail_id"}.each do |name|
        if id = fields[name]?.try(&.as_s?)
          ensure_upload_reach!(::PlaceOS::Model::Upload.find!(id), required: ::PlaceOS::Model::Permissions::Read)
        end
      end
      if type.in?({"api_key", "edge", "group_users"}) && (id = fields["user_id"]?.try(&.as_s?))
        ensure_authority_reach!(::PlaceOS::Model::User.find!(id).authority_id, "user", required: ::PlaceOS::Model::Permissions::Read)
      end
    end

    @[AC::Route::Filter(:before_action, only: [:show])]
    def find_current_history(id : UUID)
      Log.context.set(history_id: id.to_s)
      entry = ::PlaceOS::Model::History.find!(id)
      ensure_history_reach!(entry)
      @current_history = entry
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
      query = scope_history(::PlaceOS::Model::History.order(created_at: :desc, id: :desc))
      query = query.where(resource_type: resource_types) if resource_types && !resource_types.empty?
      query = query.where_not(resource_type: exclude_resource_types) if exclude_resource_types && !exclude_resource_types.empty?
      query = query.where(resource_id: resource_id) if resource_id
      query = query.where(correlation_id: correlation_id) if correlation_id
      query = query.where(user_id: user_id) if user_id
      query = query.where(action: actions) if actions && !actions.empty?
      query = query.where("created_at >= ?", Time.unix(period_start)) if period_start
      query = query.where("created_at < ?", Time.unix(period_end)) if period_end

      paginate_sql(query, type: "history", limit: limit.clamp(0, 10_000), offset: offset.clamp(0, 1_000_000)).map { |entry| history_view(entry) }
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::History
      history_view(current_history)
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
      if Utils::Tenancy.enforce? && !platform_history?
        entry = ::PlaceOS::Model::History.for_resource(resource_type, resource_id).where(action: "delete").first?
        raise Error::NotFound.new("deleted record not found") unless entry
        ensure_history_reach!(entry, ::PlaceOS::Model::Permissions::Create)
        ensure_restore_snapshot!(entry)
      end
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
