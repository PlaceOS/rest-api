require "uuid"
require "placeos-models/group/signage_template"

require "../application"

module PlaceOS::Api
  class SignageTemplates < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/signage/templates"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :approvers]
    before_action :can_write, only: [:create, :update, :destroy, :destroy_draft, :share, :request_approval, :approve]

    ###############################################################################################

    # NOTE: all routes address the approved (live) template id — drafts are
    # transparent, resolved internally, and never addressed by their own id.
    @[AC::Route::Filter(:before_action, except: [:index, :create, :share, :approvers])]
    def current_template(id : UUID)
      Log.context.set(template_id: id.to_s)
      # Find will raise a 404 (not found) if there is an error
      @current_template = template = ::PlaceOS::Model::SignageTemplate.find!(id)

      # draft ids are an implementation detail (and carry no group links)
      raise Error::NotFound.new("template #{id} not found") if template.draft?

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == template.authority_id
    end

    getter! current_template : ::PlaceOS::Model::SignageTemplate

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :template_update)]
    def parse_update_template(@template_update : ::PlaceOS::Model::SignageTemplate)
    end

    getter! template_update : ::PlaceOS::Model::SignageTemplate

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

    # Permissions
    ###############################################################################################
    #
    # Access model (same as signage playlists):
    # - sys_admin / support users bypass all checks (`user_support?`
    #   already includes admin).
    # - Regular users get access via groups carrying the "signage"
    #   subsystem: each action requires the matching Permissions bit on
    #   at least one group the template is linked to (via
    #   GroupSignageTemplate) that the user is a member of.
    # - A template with no GroupSignageTemplate rows is admin/support-only.

    # Groups this template is linked to — memoised per controller
    # instance so multiple guards share the same query.
    private def linked_template_groups : Array(UUID)
      @linked_template_groups ||= ::PlaceOS::Model::GroupSignageTemplate
        .where(signage_template_id: current_template.id.as(UUID))
        .to_a
        .map(&.group_id)
    end

    @linked_template_groups : Array(UUID)? = nil

    private def enforce_template_access!(&block : ::PlaceOS::Model::Permissions -> Bool)
      return if user_support?
      raise Error::Forbidden.new if linked_template_groups.empty?
      perms = effective_permissions_for(current_user, linked_template_groups)
      raise Error::Forbidden.new unless block.call(perms)
    end

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_read_access
      enforce_template_access!(&.read?)
    end

    @[AC::Route::Filter(:before_action, only: [:update, :destroy_draft])]
    def check_update_access
      enforce_template_access!(&.update?)
    end

    # `group_id` switches destroy from "delete the template" to "unlink the
    # template from this one group": the caller then only needs Delete (or
    # Manage) on that group rather than on the template's linked groups.
    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_destroy_access(group_id : UUID? = nil)
      if group_id
        ensure_group_delete_access!(group_id)
      else
        enforce_template_access!(&.delete?)
      end
    end

    @[AC::Route::Filter(:before_action, only: [:approve])]
    def check_approve_access
      enforce_template_access!(&.approve?)
    end

    # Draft resolution
    ###############################################################################################
    #
    # Approved templates are never edited in place: pending changes live on a
    # separate draft row (live_template_id == parent id) which is promoted via
    # `approve_draft!`. A parent that has never been approved is its own
    # unapproved version and is edited directly.

    private def find_draft(parent : ::PlaceOS::Model::SignageTemplate) : ::PlaceOS::Model::SignageTemplate?
      ::PlaceOS::Model::SignageTemplate
        .where(live_template_id: parent.id.as(UUID))
        .order(created_at: :desc)
        .limit(1)
        .to_a
        .first?
    end

    private def new_draft_from(parent : ::PlaceOS::Model::SignageTemplate) : ::PlaceOS::Model::SignageTemplate
      draft = ::PlaceOS::Model::SignageTemplate.new
      draft.authority_id = parent.authority_id
      draft.name = parent.name
      draft.description = parent.description
      draft.tags = parent.tags
      draft.background_item_id = parent.background_item_id
      draft.layouts = parent.layouts
      draft.full_screen_takeover = parent.full_screen_takeover
      draft.live_template_id = parent.id.as(UUID)
      draft
    end

    # `_present?` reflects exactly the keys present in the request body.
    # NOTE: SignageTemplate inherits PgORM::Base directly, so the JSON body
    # parser in application.cr skips its ModelBase re-parse — `_assigned?`
    # and `_changed?` are NOT usable here, only the from_json presence flags.
    private def apply_metadata!(target : ::PlaceOS::Model::SignageTemplate, update : ::PlaceOS::Model::SignageTemplate) : Nil
      target.name = update.name if update.name_present?
      # empty strings clear nilable fields (same as assign_attributes_from_json)
      target.description = update.description.presence if update.description_present?
      target.tags = update.tags if update.tags_present?
    end

    private def apply_layout!(target : ::PlaceOS::Model::SignageTemplate, update : ::PlaceOS::Model::SignageTemplate) : Nil
      target.background_item_id = update.background_item_id.presence if update.background_item_id_present?
      target.layouts = update.layouts if update.layouts_present?
      target.full_screen_takeover = update.full_screen_takeover if update.full_screen_takeover_present?
    end

    ###############################################################################################

    # list signage templates in the current authority. Only approved (live)
    # templates are returned — pending drafts are resolved via `show`.
    #
    # Non-admin callers see only templates linked to groups they're a
    # member of (direct or transitive). Pass `group_id=...` to scope to
    # a specific group (caller must have Read on that group). Pass
    # `q=...` for a case-insensitive substring search over `name` and
    # `description`.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter to templates linked to this group (caller must have Read on the group)")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "case-insensitive substring search on name and description (SQL ILIKE)")]
      q : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::SignageTemplate)
      query = ::PlaceOS::Model::SignageTemplate
        .where(authority_id: authority.id.as(String))
        .where(live_template_id: nil)

      if group_id
        unless user_support?
          perms = group_memberships(current_user)[group_id]? || ::PlaceOS::Model::Permissions::None
          raise Error::Forbidden.new unless perms.read?
        end
        linked_ids = ::PlaceOS::Model::GroupSignageTemplate
          .where(group_id: group_id)
          .to_a
          .map(&.signage_template_id)
        if linked_ids.empty?
          set_collection_headers(0, "templates")
          return [] of ::PlaceOS::Model::SignageTemplate
        end
        query = query.where(id: linked_ids)
      elsif !user_support?
        # Regular user with no group_id filter: scope to every template
        # linked to a group they have Read access on.
        viewable = group_memberships(current_user).compact_map do |g_id, g_perms|
          g_id if g_perms.read?
        end
        if viewable.empty?
          set_collection_headers(0, "templates")
          return [] of ::PlaceOS::Model::SignageTemplate
        end
        linked_ids = ::PlaceOS::Model::GroupSignageTemplate
          .where(group_id: viewable)
          .to_a
          .map(&.signage_template_id)
          .uniq!
        if linked_ids.empty?
          set_collection_headers(0, "templates")
          return [] of ::PlaceOS::Model::SignageTemplate
        end
        query = query.where(id: linked_ids)
      end

      if (term = q) && !term.empty?
        pattern = "%#{term}%"
        query = query.where("(name ILIKE ? OR description ILIKE ?)", pattern, pattern)
      end

      # newest templates first; id tiebreak keeps pagination stable
      query = query.order("created_at DESC, id")

      paginate_sql(query, type: "templates", limit: limit, offset: offset)
    end

    # return the details of the requested template. By default the pending
    # draft is returned when one exists (falling back to the approved
    # version); pass `approved=true` for the approved version always.
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "return the approved (live) version even when a pending draft exists")]
      approved : Bool = false,
    ) : ::PlaceOS::Model::SignageTemplate
      return current_template if approved
      find_draft(current_template) || current_template
    end

    # update a template. Approved templates are never modified in place:
    # changes to layout fields (background_item_id, layouts,
    # full_screen_takeover) are staged on a draft which must be approved
    # before going live. Metadata (name, description, tags) is applied
    # directly without approval. Responds with the pending version — the
    # same record the default `show` returns.
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::SignageTemplate
      update = template_update
      parent = current_template

      metadata_provided = update.name_present? || update.description_present? || update.tags_present?
      layout_provided = update.background_item_id_present? || update.layouts_present? ||
                        update.full_screen_takeover_present?

      on_primary do
        draft = find_draft(parent)

        ::PgORM::Database.transaction do |_tx|
          if metadata_provided
            # metadata doesn't require approval — applied to the approved
            # version and kept in sync on any pending draft
            apply_metadata!(parent, update)
            parent.authority_id = authority.id.as(String)
            raise Error::ModelValidation.new(parent.errors) unless parent.save
            if existing = draft
              apply_metadata!(existing, update)
              raise Error::ModelValidation.new(existing.errors) unless existing.save
            end
          end

          if layout_provided
            if !parent.approved
              # never been approved — the parent is the unapproved version
              apply_layout!(parent, update)
              raise Error::ModelValidation.new(parent.errors) unless parent.save
            else
              draft ||= new_draft_from(parent)
              apply_layout!(draft, update)
              raise Error::ModelValidation.new(draft.errors) unless draft.save
            end
          end
        end

        draft || parent
      end
    end

    # add a new signage template. Non-admin callers must supply `group_id`
    # and hold Create permission on that group — the template is
    # auto-linked to the group via a GroupSignageTemplate junction row so
    # the creator can see it immediately. Admin/support callers may omit
    # `group_id`, in which case the template is created unlinked
    # (admin-only visibility). New templates start unapproved.
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create(
      @[AC::Param::Info(description: "group id to auto-link the new template to (required for non-admin callers)")]
      group_id : UUID? = nil,
    ) : ::PlaceOS::Model::SignageTemplate
      template = template_update
      template.authority_id = authority.id.as(String)

      unless user_support?
        raise Error::Forbidden.new("group_id required") if group_id.nil?
        perms = group_memberships(current_user)[group_id]? || ::PlaceOS::Model::Permissions::None
        raise Error::Forbidden.new("missing Create permission on the target group") unless perms.create?
      end

      ::PgORM::Database.transaction do |_tx|
        raise Error::ModelValidation.new(template.errors) unless template.save
        if group_id
          link = ::PlaceOS::Model::GroupSignageTemplate.new(
            group_id: group_id,
            signage_template_id: template.id.as(UUID),
          )
          raise Error::ModelValidation.new(link.errors) unless link.save
        end
      end

      template
    end

    # remove a signage template (pending drafts and group links cascade).
    # With `group_id` the template is unlinked from that group (its
    # `GroupSignageTemplate` row is removed) and remains available to any
    # other groups it is shared with; when that was its last group link the
    # template itself is deleted so nothing is orphaned.
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      @[AC::Param::Info(description: "remove the template from this group instead of deleting it outright (caller needs Delete or Manage on the group); the template is deleted if no group links remain")]
      group_id : UUID? = nil,
    ) : Nil
      return current_template.destroy unless group_id

      template_id = current_template.id.as(UUID)
      link = ::PlaceOS::Model::GroupSignageTemplate.find?({group_id, template_id})
      raise Error::NotFound.new("template is not linked to group #{group_id}") unless link

      ::PgORM::Database.transaction do |_tx|
        link.destroy
        remaining = ::PlaceOS::Model::GroupSignageTemplate.where(signage_template_id: template_id).count
        current_template.destroy if remaining == 0
      end
    end

    # discard the pending draft, reverting to the approved version
    @[AC::Route::DELETE("/:id/draft", status_code: HTTP::Status::ACCEPTED)]
    def destroy_draft : Nil
      draft = on_primary { find_draft(current_template) }
      raise Error::NotAcceptable.new("template has no pending draft") unless draft
      draft.destroy
    end

    # Share one or more templates into another signage group via
    # `GroupSignageTemplate` junctions. Existing junctions are preserved
    # (no duplicates); the response separates newly-created links
    # from ones that were already in place.
    #
    # Permissions:
    # - sys_admin / support: any signage group in the caller's authority.
    # - regular user: must hold Share or Manage on the target group, and
    #   must have Read on each template they're trying to share.
    #
    # All templates and the target group must share the caller's
    # authority.
    @[AC::Route::POST("/share", converters: {items: ConvertStringArray})]
    def share(
      @[AC::Param::Info(description: "comma-separated template ids to share into the target group")]
      items : Array(String),
      @[AC::Param::Info(description: "target group id (must participate in the 'signage' subsystem)", name: "to")]
      to : UUID,
    ) : NamedTuple(linked: Array(String), already_present: Array(String))
      return {linked: [] of String, already_present: [] of String} if items.empty?

      template_ids = items.map do |item|
        begin
          UUID.new(item)
        rescue ArgumentError
          raise Error::NotFound.new("invalid template id #{item}")
        end
      end

      target_group = resolve_share_target_group(to)
      ensure_share_permission!(target_group)
      verify_items_in_authority!(template_ids)
      ensure_caller_can_read_items!(template_ids) unless user_support?

      group_id = target_group.id.as(UUID)
      existing = ::PlaceOS::Model::GroupSignageTemplate
        .where(group_id: group_id, signage_template_id: template_ids)
        .to_a
        .map(&.signage_template_id)
      to_link = template_ids - existing

      ::PgORM::Database.transaction do |_tx|
        to_link.each do |template_id|
          link = ::PlaceOS::Model::GroupSignageTemplate.new(
            group_id: group_id,
            signage_template_id: template_id,
          )
          raise Error::ModelValidation.new(link.errors) unless link.save
        end
      end

      {linked: to_link.map(&.to_s), already_present: existing.map(&.to_s)}
    end

    private def resolve_share_target_group(to : UUID) : ::PlaceOS::Model::Group
      group = ::PlaceOS::Model::Group.find!(to)
      raise Error::Forbidden.new("target group must be in the same authority") unless group.authority_id == authority.id
      raise Error::Forbidden.new("target group must participate in the 'signage' subsystem") unless group.subsystems.includes?("signage")
      group
    end

    private def ensure_share_permission!(target_group : ::PlaceOS::Model::Group) : Nil
      return if user_support?
      target_gid = target_group.id.as(UUID)
      perms = group_memberships(current_user)[target_gid]? || ::PlaceOS::Model::Permissions::None
      raise Error::Forbidden.new("missing Share permission on the target group") unless perms.share? || perms.manage?
    end

    # only approved (live) templates can be shared — draft rows never match
    # as they belong to the same authority but carry a live_template_id
    private def verify_items_in_authority!(template_ids : Array(UUID)) : Nil
      found = ::PlaceOS::Model::SignageTemplate
        .where(id: template_ids, authority_id: authority.id.as(String), live_template_id: nil)
        .to_a
      raise Error::NotFound.new("one or more templates not found in this authority") unless found.size == template_ids.size
    end

    # Non-support callers need at least one of Read / Share / Manage on
    # the groups every template is currently linked to. Templates with no
    # junction rows are admin-only — regular users can't share them.
    private def ensure_caller_can_read_items!(template_ids : Array(UUID)) : Nil
      junctions = ::PlaceOS::Model::GroupSignageTemplate.where(signage_template_id: template_ids).to_a
      groups_per_item = Hash(UUID, Array(UUID)).new { |h, k| h[k] = [] of UUID }
      junctions.each { |j| groups_per_item[j.signage_template_id] << j.group_id }

      memberships = group_memberships(current_user)
      template_ids.each do |template_id|
        groups = groups_per_item[template_id]
        raise Error::Forbidden.new("no read access to template #{template_id}") if groups.empty?
        perms = groups.reduce(::PlaceOS::Model::Permissions::None) do |acc, gid|
          acc | (memberships[gid]? || ::PlaceOS::Model::Permissions::None)
        end
        next if perms.read? || perms.share? || perms.manage?
        raise Error::Forbidden.new("no read access to template #{template_id}")
      end
    end

    # Approval
    # ========

    # approve the pending changes for a template. Promotes the pending
    # draft onto the live template (or approves a template that has never
    # been approved). 406 when there is nothing to approve.
    @[AC::Route::POST("/:id/approve")]
    def approve : ::PlaceOS::Model::SignageTemplate
      parent = current_template

      # resolve the draft from the primary so recently-staged changes
      # aren't missed (which would approve a stale version)
      on_primary do
        if draft = find_draft(parent)
          begin
            draft.approve_draft!(current_user)
          rescue error : ::PlaceOS::Model::Error
            raise Error::NotAcceptable.new(error.message || "unable to approve draft")
          end
        elsif !parent.approved
          parent.approver = current_user
          raise Error::ModelValidation.new(parent.errors) unless parent.save
          parent
        else
          raise Error::NotAcceptable.new("template has no unapproved changes")
        end
      end
    end

    # Approval requests
    # =================

    # JSON body for `request_approval`
    struct ApprovalMessage
      include JSON::Serializable
      getter message : String = ""
    end

    record Approver, id : String, name : String { include JSON::Serializable }

    # Climb the group tree from `group_id`, accumulating users with Approve or
    # Manage permission at each level, and stop after the first level that
    # contains an Approve user. So managers in intermediate groups are included
    # alongside the approvers of the nearest approver-bearing ancestor. Returns
    # an empty array if no level (up to the root) has an approver.
    private def resolve_approver_group_users(group_id : UUID) : Array(::PlaceOS::Model::GroupUser)
      approvers = [] of ::PlaceOS::Model::GroupUser

      current = group_id
      loop do
        group = ::PlaceOS::Model::Group.find?(current)
        break if group.nil?
        members = ::PlaceOS::Model::GroupUser.where(group_id: current).to_a
        approvers.concat(members.select { |gu| gu.permission_flags.approve? || gu.permission_flags.manage? })
        break if members.any?(&.permission_flags.approve?)
        parent = group.parent_id
        break if parent.nil?
        current = parent
      end

      approvers
    end

    # Validate the group exists in this authority and (for non-support) that
    # the caller is a member of it or one of its ancestors.
    private def validate_approval_group!(group_id : UUID) : ::PlaceOS::Model::Group
      group = ::PlaceOS::Model::Group.find?(group_id)
      raise Error::NotFound.new("group not found") if group.nil? || group.authority_id != authority.id
      return group if user_support?
      raise Error::Forbidden.new("not a member of the group") if group_memberships(current_user)[group_id]?.nil?
      group
    end

    # list the users who can approve templates for a group (those with the
    # Approve or Manage permission), climbing to the nearest ancestor group
    # that has approvers.
    @[AC::Route::GET("/approvers")]
    def approvers(
      @[AC::Param::Info(description: "group to find approvers for")]
      group_id : UUID,
    ) : Array(Approver)
      validate_approval_group!(group_id)
      members = resolve_approver_group_users(group_id)
      selectable = members.select { |gu| gu.permission_flags.approve? || gu.permission_flags.manage? }.map(&.user_id)
      return [] of Approver if selectable.empty?
      ::PlaceOS::Model::User.where(id: selectable).to_a.map { |u| Approver.new(id: u.id.as(String), name: u.name) }
    end

    # request approval for a template's pending changes. Notifies the group's
    # approvers (or a specific `approver_id`) by queuing a PendingMail for the
    # signage mailer. Any member of the group (or a parent group) may request.
    @[AC::Route::POST("/:id/request_approval", body: :message)]
    def request_approval(
      message : ApprovalMessage,
      @[AC::Param::Info(description: "group whose approvers should be notified")]
      group_id : UUID,
      @[AC::Param::Info(description: "notify only this approver (must have approve or manage permission in the group)")]
      approver_id : String? = nil,
    ) : Nil
      group = validate_approval_group!(group_id)

      members = resolve_approver_group_users(group_id)
      approver_ids = members.select(&.permission_flags.approve?).map(&.user_id)
      raise Error::NotAcceptable.new("no approvers available for this group") if approver_ids.empty? && approver_id.nil?

      recipient_ids =
        if selected = approver_id
          selectable = members.map(&.user_id)
          raise Error::NotAcceptable.new("selected approver cannot approve this template") unless selectable.includes?(selected)
          [selected]
        else
          approver_ids
        end

      send_to = ::PlaceOS::Model::User.where(id: recipient_ids).to_a.map(&.email.to_s)
      raise Error::NotAcceptable.new("no approver email addresses available") if send_to.empty?

      # the unapproved version the request refers to (select from the primary
      # so a recently-created draft isn't missed)
      parent = current_template
      target = on_primary { find_draft(parent) || parent }
      raise Error::NotAcceptable.new("template has no unapproved changes to request approval for") if !target.draft? && target.approved

      zone_ids = ::PlaceOS::Model::GroupZone.where(group_id: group_id, deny: false).to_a.map(&.zone_id).uniq!

      args = {} of String => (String | Int64 | Float64 | Bool | Nil)
      args["group_name"] = group.name
      args["group_id"] = group.id.to_s
      args["template_name"] = parent.name
      args["template_id"] = parent.id.to_s
      args["user_name"] = current_user.name
      args["user_email"] = current_user.email.to_s
      args["message"] = message.message
      ref = "template-#{parent.id}"

      mail = ::PlaceOS::Model::PendingMail.new(
        authority_id: authority.id.as(String),
        user_id: current_user.id.as(String),
        send_to: send_to,
        template: ["signage", "request_template_approval"],
        source_service: "signage",
        source_reference: ref,
        zones: zone_ids,
        expiry: 3.days.from_now,
        args: args,
      )
      raise Error::ModelValidation.new(mail.errors) unless mail.save
      target.class.update(target.id, {approval_requested: true, requested_by_id: current_user.id})

      ::PlaceOS::Driver::RedisStorage.with_redis &.publish("placeos/#{authority.id}/pending_mail/new", {
        id:        mail.id.to_s,
        service:   "signage",
        reference: ref,
      }.to_json)
    end
  end
end
