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
    # Access model: mappings inherit the permissions of the TEMPLATE they
    # apply — the caller's effective permission bits across the groups the
    # template is linked to (via GroupSignageTemplate), same as the
    # signage/templates controller. sys_admin / support bypass all checks.
    # Mappings of templates with no group links are admin/support-only.

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

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_read_access
      enforce_template_access!(mapping_template, &.read?)
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
        viewable = group_memberships(current_user).compact_map do |g_id, g_perms|
          g_id if g_perms.read?
        end
        if viewable.empty?
          set_collection_headers(0, "template_mappings")
          return [] of ::PlaceOS::Model::SignageTemplate::SystemTemplate
        end
        readable_ids = ::PlaceOS::Model::GroupSignageTemplate
          .where(group_id: viewable)
          .to_a
          .map(&.signage_template_id)
          .uniq!
        if readable_ids.empty?
          set_collection_headers(0, "template_mappings")
          return [] of ::PlaceOS::Model::SignageTemplate::SystemTemplate
        end
        query = query.where(template_id: readable_ids)
      end

      query = query.where(control_system_id: control_system_id) if control_system_id
      query = query.where(zone_id: zone_id) if zone_id
      query = query.where(template_id: template_id) if template_id

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
