require "uuid"
require "placeos-models/group/signage_template"

require "../application"

module PlaceOS::Api
  # hydrated into responses so clients don't need separate requests — the
  # caller may not have group access to fetch these records directly
  class ::PlaceOS::Model::SignageTemplate
    @[JSON::Field(ignore_deserialize: true)]
    property background_media : ::PlaceOS::Model::Playlist::Item? = nil
  end

  class ::PlaceOS::Model::SignageTemplate::SystemTemplate
    @[JSON::Field(ignore_deserialize: true)]
    property template_details : ::PlaceOS::Model::SignageTemplate? = nil
  end

  class SignageTemplateMappings < Application
    include Utils::Permissions
    include Utils::GroupPermissions

    base "/api/engine/v2/signage/template_mappings"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_mapping(id : UUID)
      Log.context.set(mapping_id: id.to_s)
      # Find will raise a 404 (not found) if there is an error
      @current_mapping = ::PlaceOS::Model::SignageTemplate::SystemTemplate.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == mapping_template.authority_id
    end

    getter! current_mapping : ::PlaceOS::Model::SignageTemplate::SystemTemplate

    # the template this mapping applies — drives all permission checks
    getter mapping_template : ::PlaceOS::Model::SignageTemplate do
      ::PlaceOS::Model::SignageTemplate.find!(current_mapping.template_id)
    end

    @[AC::Route::Filter(:before_action, only: [:create, :update], body: :mapping_update)]
    def parse_mapping(@mapping_update : ::PlaceOS::Model::SignageTemplate::SystemTemplate)
    end

    getter! mapping_update : ::PlaceOS::Model::SignageTemplate::SystemTemplate

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

    # Permissions
    ###############################################################################################
    #
    # Access model: writes inherit the permissions of the TEMPLATE they
    # apply — the caller's effective permission bits across the groups the
    # template is linked to (via GroupSignageTemplate), same as the
    # signage/templates controller. Reads are additionally granted to
    # anyone who can view the mapping's TARGET — a signage/support
    # subsystem Read grant (or legacy org-zone access) on the zone, or on
    # any of the display's zones — so viewers of a display or zone can see
    # the templates applied to it (including the hydrated template) even
    # when they can't edit them. sys_admin / support bypass all checks.
    # Mappings of unlinked templates on targets without zone grants are
    # admin/support-only.

    SIGNAGE_SUBSYSTEMS = ["signage", SUPPORT_SUBSYSTEM]

    private def linked_groups_for(template : ::PlaceOS::Model::SignageTemplate) : Array(UUID)
      ::PlaceOS::Model::GroupSignageTemplate
        .where(signage_template_id: template.id.as(UUID))
        .to_a
        .map(&.group_id)
    end

    private def enforce_template_access!(template : ::PlaceOS::Model::SignageTemplate, &block : ::PlaceOS::Model::Permissions -> Bool)
      return if user_support?
      groups = linked_groups_for(template)
      raise Error::Forbidden.new if groups.empty?
      perms = effective_permissions_for(current_user, groups)
      raise Error::Forbidden.new unless block.call(perms)
    end

    # SQL subquery of the zones on which the caller can view signage
    # configuration: a Read (or Manage) grant via the signage/support
    # subsystems, plus the legacy org-zone path. The zone set is resolved
    # in the database — never materialised in memory (there can be 1000s
    # of zones). nil means no viewable zones. Memoised per request.
    private def viewer_zone_scope_sql : String?
      return @viewer_zone_scope_sql if @viewer_zone_scope_checked
      @viewer_zone_scope_checked = true

      scope = accessible_zones_scope_sql(SIGNAGE_SUBSYSTEMS, ::PlaceOS::Model::Permissions::Read)

      legacy_zone = if (org_zone = support_org_zone_id) && check_access(current_user.groups, [org_zone]).can_manage?
                      org_zone
                    end

      @viewer_zone_scope_sql = if scope && legacy_zone
                                 "(SELECT zone_id FROM #{scope} AS a(zone_id) UNION SELECT '#{legacy_zone.gsub("'", "''")}')"
                               elsif legacy_zone
                                 "(SELECT '#{legacy_zone.gsub("'", "''")}' AS zone_id)"
                               else
                                 scope
                               end
    end

    @viewer_zone_scope_sql : String? = nil
    @viewer_zone_scope_checked : Bool = false

    # read access to the mapping's target (display or zone) grants
    # visibility of the mapping — resolved via a single EXISTS probe
    # against the viewer-zone subquery
    private def can_view_target?(mapping : ::PlaceOS::Model::SignageTemplate::SystemTemplate) : Bool
      zones = if sys_id = mapping.control_system_id.presence
                ::PlaceOS::Model::ControlSystem.find?(sys_id).try(&.zones) || [] of String
              elsif zone_id = mapping.zone_id.presence
                [zone_id]
              else
                [] of String
              end
      return false if zones.empty?
      return false unless scope = viewer_zone_scope_sql

      zones_sql = ::PlaceOS::Model::Associations.format_list_for_postgres(zones)
      ::PgORM::Database.connection do |db|
        db.query_one(
          "SELECT EXISTS (SELECT 1 FROM #{scope} AS v(zone_id) WHERE v.zone_id = ANY(#{zones_sql}))",
          &.read(Bool)
        )
      end
    end

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_read_access
      return if user_support?

      groups = linked_groups_for(mapping_template)
      return if !groups.empty? && effective_permissions_for(current_user, groups).read?
      return if can_view_target?(current_mapping)

      raise Error::Forbidden.new
    end

    @[AC::Route::Filter(:before_action, only: [:update])]
    def check_update_access
      enforce_template_access!(mapping_template, &.update?)
    end

    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_destroy_access
      enforce_template_access!(mapping_template, &.delete?)
    end

    # Hydration
    ###############################################################################################

    private def hydrate!(mappings : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)) : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)
      return mappings if mappings.empty?

      template_ids = mappings.map(&.template_id).uniq!
      templates = ::PlaceOS::Model::SignageTemplate
        .where(id: template_ids)
        .to_a
        .index_by(&.id.as(UUID))

      item_ids = templates.each_value.compact_map(&.background_item_id).to_a.uniq!
      items = item_ids.empty? ? {} of String => ::PlaceOS::Model::Playlist::Item : ::PlaceOS::Model::Playlist::Item.where(id: item_ids).to_a.index_by(&.id.as(String))

      templates.each_value do |template|
        if item_id = template.background_item_id
          template.background_media = items[item_id]?
        end
      end

      mappings.each do |mapping|
        mapping.template_details = templates[mapping.template_id]?
      end

      mappings
    end

    ###############################################################################################

    # list the template mappings in the current authority — what templates
    # are applied to which displays and zones. Non-admin callers see only
    # mappings of templates linked to groups they hold Read on.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter to mappings applied to this display (control system id)")]
      control_system_id : String? = nil,
      @[AC::Param::Info(description: "filter to mappings applied to this zone")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "filter to mappings of this template")]
      template_id : UUID? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)
      query = ::PlaceOS::Model::SignageTemplate::SystemTemplate
        .where("template_id IN (SELECT id FROM signage_template WHERE authority_id = ?)", authority.id.as(String))

      unless user_support?
        # templates readable via group links
        viewable = group_memberships(current_user).compact_map do |g_id, g_perms|
          g_id if g_perms.read?
        end
        readable_ids = if viewable.empty?
                         [] of UUID
                       else
                         ::PlaceOS::Model::GroupSignageTemplate
                           .where({:group_id => viewable})
                           .to_a
                           .map(&.signage_template_id)
                           .uniq!
                       end

        # targets (displays / zones) viewable via zone grants — resolved as
        # an SQL subquery so the zone set is never materialised in memory
        zone_scope = viewer_zone_scope_sql

        if readable_ids.empty? && zone_scope.nil?
          set_collection_headers(0, "template_mappings")
          return [] of ::PlaceOS::Model::SignageTemplate::SystemTemplate
        end

        conditions = [] of String
        unless readable_ids.empty?
          conditions << "template_id IN (#{readable_ids.join(',') { |id| "'#{id}'" }})"
        end
        if zone_scope
          conditions << "zone_id IN #{zone_scope}"
          conditions << "control_system_id IN (SELECT id FROM sys WHERE zones && ARRAY#{zone_scope})"
        end
        query = query.where("(#{conditions.join(" OR ")})", [] of ::PgORM::Value)
      end

      # raw-SQL filters: pg-orm can't compile named-arg `where` chained
      # with the raw-SQL conditions above
      query = query.where("control_system_id = ?", control_system_id) if control_system_id
      query = query.where("zone_id = ?", zone_id) if zone_id
      query = query.where("template_id = ?", template_id) if template_id

      hydrate! paginate_sql(query, type: "template_mappings", limit: limit, offset: offset)
    end

    # return the details of a template mapping, including the applied
    # template and its background media
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::SignageTemplate::SystemTemplate
      hydrate!([current_mapping]).first
    end

    # apply a template to a display (control system) or a zone — exactly one
    # of the two. A mapping without a schedule is the default template for
    # the pairing (at most one); scheduled mappings show the template during
    # the schedule. Requires Create permission on the template's groups.
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::SignageTemplate::SystemTemplate
      mapping = mapping_update

      # the template must exist in this authority and not be a pending draft
      # (drafts are transparent — only approved templates are applied)
      template = ::PlaceOS::Model::SignageTemplate.find!(mapping.template_id)
      if template.authority_id != authority.id || template.draft?
        raise Error::NotFound.new("template #{mapping.template_id} not found")
      end

      enforce_template_access!(template, &.create?)

      # clean 404s for missing targets (the XOR rule itself is a model validation)
      if sys_id = mapping.control_system_id.presence
        ::PlaceOS::Model::ControlSystem.find!(sys_id)
      end
      if zone_id = mapping.zone_id.presence
        ::PlaceOS::Model::Zone.find!(zone_id)
      end

      raise Error::ModelValidation.new(mapping.errors) unless mapping.save
      hydrate!([mapping]).first
    end

    # update the schedule of a template mapping. Only the schedule can be
    # changed — apply a template elsewhere by removing the mapping and
    # creating a new one. An explicit `"schedule": null` clears the schedule,
    # making this mapping the default for its pairing.
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::SignageTemplate::SystemTemplate
      mapping = current_mapping
      # NOTE: SystemTemplate inherits PgORM::Base directly, so only the
      # from_json `_present?` flags reflect the request body (see the
      # application.cr JSON parser — `_assigned?` is never set here)
      mapping.schedule = mapping_update.schedule if mapping_update.schedule_present?
      raise Error::ModelValidation.new(mapping.errors) unless mapping.save
      hydrate!([mapping]).first
    end

    # remove a template mapping from a display or zone
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_mapping.destroy
    end
  end
end
