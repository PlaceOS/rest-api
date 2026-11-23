require "upload-signer"
require "uuid"
require "placeos-models/group/playlist_item"

require "../application"

module PlaceOS::Api
  # hydrated into `show` responses so clients can see which groups an item
  # has been shared into without a second request — the caller may not be a
  # member of every one of those groups, so it can't resolve the records
  # itself. Nil is omitted from JSON, so other routes are unaffected.
  class ::PlaceOS::Model::Playlist::Item
    @[JSON::Field(ignore_deserialize: true)]
    property shared_with : Array(::PlaceOS::Model::Group)? = nil

    # the playlists this item currently appears in, filtered to those the
    # caller can read. Also `show` only, also omitted when nil.
    @[JSON::Field(ignore_deserialize: true)]
    property playlists : Array(::PlaceOS::Model::Playlist)? = nil
  end

  # Digital signage media: images, videos, web pages and plugins that can be played
  class PlaylistMedia < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/signage/media"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :tags, :tag_counts]
    before_action :can_write, only: [:create, :update, :destroy, :share, :rename_tag, :remove_tag]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :tags, :tag_counts, :create, :share, :rename_tag, :remove_tag])]
    def current_item(id : String)
      Log.context.set(item_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_item = item = ::PlaceOS::Model::Playlist::Item.find!(id)

      # ensure the current user has access
      authority_for_resource!(item.authority_id, "item") if Utils::Tenancy.enforce?
      raise Error::Forbidden.new unless authority.id == item.authority_id
    end

    getter! current_item : ::PlaceOS::Model::Playlist::Item

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :item_update)]
    def parse_update_item(@item_update : ::PlaceOS::Model::Playlist::Item)
    end

    getter! item_update : ::PlaceOS::Model::Playlist::Item

    getter authority : ::PlaceOS::Model::Authority { resource_authority! }

    # Permissions
    ###############################################################################################
    #
    # Same model as Playlist — admin/support bypass; regular users need
    # the appropriate permission bit on a group linked to the item via
    # GroupPlaylistItem. Items with no junction rows are admin-only.

    private def linked_item_groups : Array(UUID)
      @linked_item_groups ||= ::PlaceOS::Model::GroupPlaylistItem
        .where(playlist_item_id: current_item.id)
        .to_a
        .map(&.group_id)
    end

    @linked_item_groups : Array(UUID)? = nil

    private def enforce_item_access!(&block : ::PlaceOS::Model::Permissions -> Bool)
      return if user_support?
      raise Error::Forbidden.new if linked_item_groups.empty?
      perms = effective_permissions_for(current_user, linked_item_groups)
      raise Error::Forbidden.new unless block.call(perms)
    end

    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_read_access
      enforce_item_access!(&.read?)
    end

    @[AC::Route::Filter(:before_action, only: [:update])]
    def check_update_access
      enforce_item_access!(&.update?)
    end

    # `group_id` switches destroy from "delete the item" to "unlink the item
    # from this one group": the caller then only needs Delete (or Manage) on
    # that group rather than on the item's linked groups.
    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_destroy_access(group_id : UUID? = nil)
      if group_id
        ensure_group_delete_access!(group_id)
      else
        enforce_item_access!(&.delete?)
      end
    end

    ###############################################################################################

    # Raw-SQL `WHERE id IN (...junction subquery...)` fragment scoping
    # `playlist_items` to those linked to any of `group_ids`. Each group id
    # is a bound `?` placeholder (never interpolated). Caller guarantees
    # `group_ids` is non-empty.
    private def linked_item_subquery(group_ids : Array(UUID)) : String
      placeholders = Array.new(group_ids.size, "?").join(", ")
      "id IN (SELECT playlist_item_id FROM group_playlist_items WHERE group_id IN (#{placeholders}))"
    end

    # list media items for the current authority.
    #
    # Non-admin callers see only items linked to groups they're a member
    # of (direct or transitive). `group_id=...` scopes to a single
    # group by default. `q=...` is a case-insensitive substring search across
    # `name` and `description`; `tags=...` returns items carrying any of
    # the supplied tags.
    @[AC::Route::GET("/", converters: {tags: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "filter to items linked to this group (caller must have Read on the group)")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "with group_id, also include items linked to readable descendant groups", example: "true")]
      include_child_data : Bool = false,
      @[AC::Param::Info(description: "case-insensitive substring search on name and description (SQL ILIKE)")]
      q : String? = nil,
      @[AC::Param::Info(description: "return items carrying any of these tags", example: "promo,lobby")]
      tags : Array(String)? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::Playlist::Item)
      query = scope_resource_authorities(::PlaceOS::Model::Playlist::Item.all)

      scope = readable_group_scope(group_id, include_child_data)
      unless scope.nil?
        if scope.empty?
          set_collection_headers(0, "playlist_items")
          return [] of ::PlaceOS::Model::Playlist::Item
        end
        query = query.where(linked_item_subquery(scope), args: scope)
      end

      if (term = q) && !term.empty?
        pattern = "%#{term}%"
        query = query.where("(name ILIKE ? OR description ILIKE ?)", pattern, pattern)
      end

      # overlap (`&&`) => items carrying at least one of the requested tags.
      # Bind each tag individually so values are never interpolated into SQL.
      if (filter_tags = tags) && !filter_tags.empty?
        placeholders = Array.new(filter_tags.size, "?").join(", ")
        query = query.where("tags && ARRAY[#{placeholders}]::text[]", args: filter_tags)
      end

      # newest items first; id tiebreak keeps pagination stable
      query = query.order("created_at DESC, id")

      paginate_sql(query, type: "playlist_items", limit: limit, offset: offset)
    end

    # return the distinct tags in use by media. Scopes the same way as
    # `index`: `group_id=...` limits to media linked to that group by default (caller
    # must have Read on it). Without `group_id`, admin/support callers see
    # every tag in the authority while regular users see tags from media in
    # groups they can read.
    @[AC::Route::GET("/tags")]
    def tags(
      @[AC::Param::Info(description: "limit to media linked to this group (caller must have Read on the group)")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "with group_id, also include tags on media linked to readable descendant groups", example: "true")]
      include_child_data : Bool = false,
    ) : Array(String)
      scope = readable_group_scope(group_id, include_child_data)
      return [] of String if !scope.nil? && scope.empty?

      # Distinct tags computed in SQL — we never materialize item ids. The
      # optional group scope is a subquery against the junction table, keyed
      # on the bounded `group_id = ANY($2)` array.
      sql = String.build do |str|
        str << "SELECT DISTINCT unnest(tags) AS tag FROM playlist_items WHERE authority_id = ANY($1::text[])"
        str << " AND id IN (SELECT playlist_item_id FROM group_playlist_items WHERE group_id = ANY($2::uuid[]))" unless scope.nil?
        str << " ORDER BY tag"
      end

      PgORM::Database.connection do |db|
        if scope.nil?
          db.query_all(sql, args: [resource_authority_ids], as: String)
        else
          db.query_all(sql, args: [resource_authority_ids, scope.map(&.to_s)], as: String)
        end
      end
    end

    # Tag maintenance
    ###############################################################################################
    #
    # Renaming or removing a tag rewrites every item that carries it, so
    # without `group_id` (all media in the authority) the caller must be
    # admin/support. With `group_id` only media linked to that group is
    # touched; the group must exist in the caller's authority (404
    # otherwise) and the caller needs Read plus `required` on it — Manage
    # covers everything — as effective permissions, so an ancestor grant
    # counts. Returns the scope for the SQL: `nil` for the whole authority,
    # else the single group.
    private def tag_operation_scope(group_id : UUID?, required : ::PlaceOS::Model::Permissions) : Array(UUID)?
      if group_id
        ensure_group_access!(group_id, ::PlaceOS::Model::Permissions::Read | required)
        return [group_id]
      end
      raise Error::Forbidden.new("group_id is required unless the caller is admin or support") unless user_support?
      nil
    end

    private def with_tag_operation_scope(group_id : UUID?, include_child_data : Bool, required : ::PlaceOS::Model::Permissions, &) : Nil
      unless group_id && include_child_data
        yield tag_operation_scope(group_id, required)
        return
      end

      # Authorise and mutate the same snapshot of group links, tags and
      # permissions. Concurrent changes to the rows we write cause a conflict.
      PgORM::Database.transaction do |tx|
        tx.connection.exec("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        ensure_group_access!(group_id, ::PlaceOS::Model::Permissions::Read)
        yield readable_group_scope(group_id, include_child_data: true)
      end
    end

    private def ensure_tag_operation_access!(tag : String, scope : Array(UUID)?, required : ::PlaceOS::Model::Permissions) : Nil
      return unless scope
      return if user_support?

      permitted = group_memberships(current_user).compact_map do |id, perms|
        id if perms.manage? || perms.includes?(required)
      end
      # Unlinking needs permission on each affected link. A tag is part of
      # the media record, so any link granting Update permits editing it.
      unlinking = required.delete?
      check_scope = unlinking ? scope - permitted : scope
      return if check_scope.empty?

      sql = String.build do |str|
        str << "SELECT EXISTS(SELECT 1 FROM playlist_items WHERE authority_id = $1 AND $2 = ANY(tags)"
        str << tag_scope_sql(check_scope, 3)
        str << " AND id NOT IN (#{tag_linked_items_sql(4)})" unless unlinking
        str << ")"
      end
      args = [authority.id.as(String), tag, check_scope.map(&.to_s)]
      args << permitted.map(&.to_s) unless unlinking
      denied = PgORM::Database.connection(&.scalar(sql, args: args)).as(Bool)
      raise Error::Forbidden.new("missing #{required} permission on some of the tagged media") if denied
    end

    # tags are free text so the only invalid value is a blank one
    private def require_tag(value : String, param : String) : String
      raise AC::Route::Param::ValueError.new("must not be blank", param) if value.blank?
      value
    end

    # Junction-table scope fragment for the raw tag UPDATEs below; the group
    # ids are bound as `$n::uuid[]`, never interpolated.
    private def tag_scope_sql(scope : Array(UUID)?, param : Int32) : String
      return "" if scope.nil?
      " AND id IN (#{tag_linked_items_sql(param)})"
    end

    private def tag_linked_items_sql(param : Int32) : String
      "SELECT playlist_item_id FROM group_playlist_items WHERE group_id = ANY($#{param}::uuid[])"
    end

    # rename a tag on every media item carrying it. Items that already carry
    # `new_tag` end up with it once. Authority-wide is admin/support only.
    # A single-group operation requires Read and Update (or Manage) on that
    # group. An expanded operation requires Update access to every matched item.
    @[AC::Route::PATCH("/tags")]
    def rename_tag(
      @[AC::Param::Info(description: "the existing tag to be renamed")]
      current_tag : String,
      @[AC::Param::Info(description: "the replacement tag name")]
      new_tag : String,
      @[AC::Param::Info(description: "select the media group. A single-group rename requires Read and Update on that group.")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "with group_id, also include media linked to readable descendant groups. Every matched item must allow Update.", example: "true")]
      include_child_data : Bool = false,
    ) : Nil
      current_tag = require_tag(current_tag, "current_tag")
      # apply the same sanitisation the model applies to the tags attribute
      new_tag = require_tag(::ActiveModel::Sanitizer.sanitize(new_tag, :text), "new_tag")
      required = ::PlaceOS::Model::Permissions::Update
      with_tag_operation_scope(group_id, include_child_data, required) do |scope|
        next if current_tag == new_tag
        ensure_tag_operation_access!(current_tag, scope, required) if include_child_data

        # After replacement, duplicates collapse to each tag's first position.
        sql = String.build do |str|
          str << "UPDATE playlist_items SET updated_at = CURRENT_TIMESTAMP, tags = ARRAY("
          str << "SELECT t FROM unnest(array_replace(tags, $2, $3)) WITH ORDINALITY AS u(t, ord) GROUP BY t ORDER BY MIN(ord)"
          str << ") WHERE authority_id = $1 AND $2 = ANY(tags)"
          str << tag_scope_sql(scope, 4)
        end

        args = [authority.id.as(String), current_tag, new_tag] of String | Array(String)
        args << scope.map(&.to_s) if scope
        PgORM::Database.connection do |db|
          db.exec(sql, args: args)
        end
      end
    end

    # remove a tag from every media item carrying it, or with
    # `remove_media=true` remove the tagged media itself. Authority-wide is
    # admin/support only. A single-group operation requires Read and Update
    # (or Manage) on that group, or Read and Delete when removing media. An
    # expanded operation requires Update on each matched item, or Delete on
    # every matched group link when removing media. Group-scoped media removal
    # keeps items that are still linked outside the scope.
    @[AC::Route::DELETE("/tags")]
    def remove_tag(
      @[AC::Param::Info(description: "the tag to be removed")]
      tag : String,
      @[AC::Param::Info(description: "if true, removes the tag by removing all the media with this tag")]
      remove_media : Bool = false,
      @[AC::Param::Info(description: "select the media group. A single-group operation requires Read and Update, or Read and Delete when removing media.")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "with group_id, also include media linked to readable descendant groups. Requires Update on every matched item, or Delete on every matched group link when removing media.", example: "true")]
      include_child_data : Bool = false,
    ) : Nil
      tag = require_tag(tag, "tag")
      required = remove_media ? ::PlaceOS::Model::Permissions::Delete : ::PlaceOS::Model::Permissions::Update
      with_tag_operation_scope(group_id, include_child_data, required) do |scope|
        ensure_tag_operation_access!(tag, scope, required) if include_child_data
        if remove_media
          remove_tagged_media!(tag, scope)
        else
          sql = "UPDATE playlist_items SET updated_at = CURRENT_TIMESTAMP, tags = array_remove(tags, $2) WHERE authority_id = $1 AND $2 = ANY(tags)#{tag_scope_sql(scope, 3)}"
          args = [authority.id.as(String), tag] of String | Array(String)
          args << scope.map(&.to_s) if scope
          PgORM::Database.connection do |db|
            db.exec(sql, args: args)
          end
        end
      end
    end

    TAG_REMOVAL_BATCH = 100

    # Media removal goes through the ORM one item at a time, inside a single
    # transaction, so `Playlist::Item`'s destroy hooks run (they strip the
    # item out of playlist revisions and bump those playlists). Items are
    # fetched in id-ordered batches with a keyset cursor so a large library
    # is never held in memory at once and progress is guaranteed even if a
    # removal leaves the row in place (unlinking a still-shared item).
    private def remove_tagged_media!(tag : String, scope : Array(UUID)?) : Nil
      return if scope.try(&.empty?)

      base = ::PlaceOS::Model::Playlist::Item
        .where(authority_id: authority.id.as(String))
        .where("? = ANY(tags)", tag)
      base = base.where(linked_item_subquery(scope), args: scope) unless scope.nil?

      PgORM::Database.transaction do |_tx|
        last_id = ""
        loop do
          batch = base.where("id > ?", last_id).order("id").limit(TAG_REMOVAL_BATCH).to_a
          break if batch.empty?
          batch.each do |item|
            if scope && scope.size > 1
              links = ::PlaceOS::Model::GroupPlaylistItem.where(playlist_item_id: item.id.as(String))
              links.where(group_id: scope).delete_all
              destroy_item!(item) unless links.exists?
            else
              remove_item!(item, scope.try(&.first))
            end
          end
          last_id = batch.last.id.as(String)
        end
      end
    end

    # return the number of media items carrying each tag. Scopes the same
    # way as `index`/`tags`: `group_id=...` limits to media linked to that
    # group by default (caller must have Read on it). Without `group_id`, admin/support
    # callers see counts across the authority while regular users see counts
    # from media in groups they can read. An item carrying a tag twice still
    # counts once.
    @[AC::Route::GET("/tag_counts")]
    def tag_counts(
      @[AC::Param::Info(description: "limit to media linked to this group (caller must have Read on the group)")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "with group_id, also count media linked to readable descendant groups", example: "true")]
      include_child_data : Bool = false,
    ) : Hash(String, Int32)
      scope = readable_group_scope(group_id, include_child_data)
      counts = {} of String => Int32
      return counts if !scope.nil? && scope.empty?

      # Aggregate in SQL — item ids are never materialised. `DISTINCT` in the
      # unnest subquery guards against duplicate tags on a single item.
      sql = String.build do |str|
        str << "SELECT t.tag, COUNT(*)::int FROM playlist_items i, LATERAL (SELECT DISTINCT unnest(i.tags) AS tag) t WHERE i.authority_id = ANY($1::text[])"
        str << " AND i.id IN (SELECT playlist_item_id FROM group_playlist_items WHERE group_id = ANY($2::uuid[]))" unless scope.nil?
        str << " GROUP BY t.tag ORDER BY t.tag"
      end

      read_counts = ->(rs : ::DB::ResultSet) do
        tag = rs.read(String)
        counts[tag] = rs.read(Int32)
      end

      PgORM::Database.connection do |db|
        if scope.nil?
          db.query_each(sql, args: [resource_authority_ids], &read_counts)
        else
          db.query_each(sql, args: [resource_authority_ids, scope.map(&.to_s)], &read_counts)
        end
      end
      counts
    end

    # return the details of the requested media item, including the groups
    # it has been shared with and the playlists it appears in
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Playlist::Item
      item = current_item
      item.shared_with = groups_by_id(linked_item_groups)
      item.playlists = playlists_containing_item
      item
    end

    # A playlist's media list lives in its most recent revision -- the same
    # one `GET /playlists/:id/media` returns (the pending draft when there is
    # one, otherwise the latest approved). Regular playlists reference media
    # ids directly; distribution playlists reference `playlist_item_schedules`
    # rows, each pointing back at a media item. Both are matched here, and the
    # correlated subqueries keep the work in Postgres -- no revision or
    # playlist ids are pulled into memory to be filtered.
    LATEST_REVISION_CONTAINS_ITEM = <<-SQL
      EXISTS (
        SELECT 1 FROM playlist_revisions r
        WHERE r.playlist_id = playlists.id
          AND r.created_at = (
            SELECT MAX(r2.created_at) FROM playlist_revisions r2
            WHERE r2.playlist_id = r.playlist_id
          )
          AND (
            ? = ANY(r.items)
            OR EXISTS (
              SELECT 1 FROM playlist_item_schedules s
              WHERE s.playlist_id = r.playlist_id AND s.item_id = ? AND s.id = ANY(r.items)
            )
          )
      )
      SQL

    # Raw-SQL `WHERE id IN (...junction subquery...)` fragment scoping
    # `playlists` to those linked to any of `group_ids` (bound placeholders,
    # never interpolated). Caller guarantees `group_ids` is non-empty.
    private def linked_playlist_subquery(group_ids : Array(UUID)) : String
      placeholders = Array.new(group_ids.size, "?").join(", ")
      "id IN (SELECT playlist_id FROM group_playlists WHERE group_id IN (#{placeholders}))"
    end

    # Playlists the item appears in, narrowed to the ones the caller may see:
    # admin/support get every playlist in the authority, everyone else only
    # those shared into a group they hold Read on (a grant on a parent group
    # covers its children, per `group_memberships`).
    private def playlists_containing_item : Array(::PlaceOS::Model::Playlist)
      scope = readable_group_scope(nil)
      return [] of ::PlaceOS::Model::Playlist if scope && scope.empty?

      item_id = current_item.id.as(String)
      query = ::PlaceOS::Model::Playlist
        .where(authority_id: authority.id.as(String))
        .where(LATEST_REVISION_CONTAINS_ITEM, item_id, item_id)
      query = query.where(linked_playlist_subquery(scope), args: scope) unless scope.nil?
      query.order("lower(name), id").to_a
    end

    # redirects to the thumbnail image URL
    @[AC::Route::GET("/:id/thumbnail")]
    def thumbnail
      raise Error::NotFound.new("no thumbnail associated") unless current_item.thumbnail_id
      current_upload = current_item.thumbnail.as(::PlaceOS::Model::Upload)
      ensure_upload_reach!(current_upload)

      unless storage = current_upload.storage
        Log.warn { {message: "upload object associated storage not found", upload_id: current_upload.id, authority: authority.id, user: current_user.id} }
        raise Error::NotFound.new("Upload #{current_upload.id} missing associated storage")
      end

      us = UploadSigner.signer(UploadSigner::StorageType.from_value(storage.storage_type.value), storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
      object_url = us.get_object(storage.bucket_name, current_upload.object_key, 60)

      redirect_to object_url, status: :see_other
    end

    private def check_item_references(item : ::PlaceOS::Model::Playlist::Item)
      return unless Utils::Tenancy.enforce?
      [item.media_id, item.thumbnail_id].compact.each do |id|
        ensure_upload_reach!(::PlaceOS::Model::Upload.find!(id))
      end
      if id = item.plugin_id
        ensure_resource_authority!(::PlaceOS::Model::SignagePlugin.find!(id).authority_id, "plugin", shared: true, required: ::PlaceOS::Model::Permissions::Read)
      end
    end

    # update the details of a media item
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::Playlist::Item
      item = item_update
      current = current_item
      current.assign_attributes(item)
      current.authority_id = authority.id
      check_item_references(current)
      PgORM::Database.transaction do |_tx|
        raise Error::ModelValidation.new(current.errors) unless current.save
        touch_media_references!(current.id.as(String))
      end
      current
    end

    # add a new media item. Non-admin callers must supply `group_id`
    # (and hold Create permission on that group); the item is
    # auto-linked via a GroupPlaylistItem junction row so the creator
    # can see it immediately.
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create(
      @[AC::Param::Info(description: "group id to auto-link the new item to (required for non-admin callers)")]
      group_id : UUID? = nil,
    ) : ::PlaceOS::Model::Playlist::Item
      item = item_update
      item.authority_id = authority.id
      check_item_references(item)

      if Utils::Tenancy.enforce? && group_id
        ensure_resource_authority!(::PlaceOS::Model::Group.find!(group_id).authority_id, "group")
      end
      unless user_support?
        raise Error::Forbidden.new("group_id required") if group_id.nil?
        perms = group_memberships(current_user)[group_id]? || ::PlaceOS::Model::Permissions::None
        raise Error::Forbidden.new("missing Create permission on the target group") unless perms.create?
      end

      ::PgORM::Database.transaction do |_tx|
        raise Error::ModelValidation.new(item.errors) unless item.save
        if group_id
          link = ::PlaceOS::Model::GroupPlaylistItem.new(
            group_id: group_id,
            playlist_item_id: item.id.as(String),
          )
          raise Error::ModelValidation.new(link.errors) unless link.save
        end
      end

      item
    end

    # Share one or more media items into another signage group via
    # `GroupPlaylistItem` junctions. Existing junctions are preserved
    # (no duplicates); the response separates newly-created links from
    # ones that were already in place.
    #
    # Permissions:
    # - sys_admin / support: any signage group in the caller's authority.
    # - regular user: must hold Share or Manage on the target group, and
    #   must have Read on each item they're trying to share.
    #
    # All items and the target group must share the caller's authority.
    @[AC::Route::POST("/share", converters: {items: ConvertStringArray})]
    def share(
      @[AC::Param::Info(description: "comma-separated item ids to share into the target group")]
      items : Array(String),
      @[AC::Param::Info(description: "target group id (must participate in the 'signage' subsystem)", name: "to")]
      to : UUID,
    ) : NamedTuple(linked: Array(String), already_present: Array(String))
      return {linked: [] of String, already_present: [] of String} if items.empty?

      target_group = resolve_share_target_group(to)
      ensure_share_permission!(target_group)
      verify_items_in_authority!(items)
      ensure_caller_can_read_items!(items) unless user_support?

      group_id = target_group.id.as(UUID)
      existing = ::PlaceOS::Model::GroupPlaylistItem
        .where(group_id: group_id, playlist_item_id: items)
        .to_a
        .map(&.playlist_item_id)
      to_link = items - existing

      ::PgORM::Database.transaction do |_tx|
        to_link.each do |item_id|
          link = ::PlaceOS::Model::GroupPlaylistItem.new(
            group_id: group_id,
            playlist_item_id: item_id,
          )
          raise Error::ModelValidation.new(link.errors) unless link.save
        end
      end

      {linked: to_link, already_present: existing}
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

    private def verify_items_in_authority!(items : Array(String)) : Nil
      found = ::PlaceOS::Model::Playlist::Item
        .where(id: items, authority_id: authority.id.as(String))
        .to_a
      raise Error::NotFound.new("one or more items not found in this authority") unless found.size == items.size
    end

    # Non-support callers need at least one of Read / Share / Manage on
    # the groups every item is currently linked to. Items with no
    # junction rows are admin-only — regular users can't share them.
    private def ensure_caller_can_read_items!(items : Array(String)) : Nil
      junctions = ::PlaceOS::Model::GroupPlaylistItem.where(playlist_item_id: items).to_a
      groups_per_item = Hash(String, Array(UUID)).new { |h, k| h[k] = [] of UUID }
      junctions.each { |j| groups_per_item[j.playlist_item_id] << j.group_id }

      memberships = group_memberships(current_user)
      items.each do |item_id|
        groups = groups_per_item[item_id]
        raise Error::Forbidden.new("no read access to item #{item_id}") if groups.empty?
        perms = groups.reduce(::PlaceOS::Model::Permissions::None) do |acc, gid|
          acc | (memberships[gid]? || ::PlaceOS::Model::Permissions::None)
        end
        next if perms.read? || perms.share? || perms.manage?
        raise Error::Forbidden.new("no read access to item #{item_id}")
      end
    end

    # remove a media item from the library. With `group_id` the item is
    # unlinked from that group (its `GroupPlaylistItem` row is removed) and
    # remains available to any other groups it is shared with; when that was
    # its last group link the item itself is deleted so nothing is orphaned.
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      @[AC::Param::Info(description: "remove the item from this group instead of deleting it outright (caller needs Delete or Manage on the group); the item is deleted if no group links remain")]
      group_id : UUID? = nil,
    ) : Nil
      remove_item!(current_item, group_id)
    end

    # delete `item` outright, or with `group_id` unlink it from that group
    # and only delete it once no group links remain. Shared by `destroy` and
    # `remove_tag`.
    private def remove_item!(item : ::PlaceOS::Model::Playlist::Item, group_id : UUID?) : Nil
      return destroy_item!(item) unless group_id

      item_id = item.id.as(String)
      link = ::PlaceOS::Model::GroupPlaylistItem.find?({group_id, item_id})
      raise Error::NotFound.new("item is not linked to group #{group_id}") unless link

      PgORM::Database.transaction do |_tx|
        link.destroy
        remaining = ::PlaceOS::Model::GroupPlaylistItem.where(playlist_item_id: item_id).count
        destroy_item!(item) if remaining == 0
      end
    end

    # Editing or deleting a media item changes what displays render, but a
    # template referencing it as background_item_id never bumps its own
    # updated_at (deletes clear the column via ON DELETE SET NULL at the DB
    # level), so signage Last-Modified caches would never bust — touch the
    # referencing templates here, before deletes so the reference still
    # resolves. Playlists need no equivalent: Playlist::Item's after_update /
    # before_destroy hooks already bump referencing playlists (and their
    # exec_sql runs on a separate connection, so bumping playlists inside
    # this transaction too would deadlock against them).
    private def touch_media_references!(item_id : String) : Nil
      ::PlaceOS::Model::SignageTemplate
        .where(background_item_id: item_id)
        .update_all(updated_at: Time.utc)
    end

    # delete the item and any uploads not referenced by other items
    private def destroy_item!(item : ::PlaceOS::Model::Playlist::Item) : Nil
      PgORM::Database.transaction do |_tx|
        touch_media_references!(item.id.as(String))

        {item.media, item.thumbnail}.each do |upload|
          next unless upload

          # don't remove upload if it's used else where
          upload_id = upload.id
          counts = Model::Playlist::Item.where("media_id = ? OR thumbnail_id = ?", upload_id, upload_id).count
          next unless counts <= 1

          # cleanup files from storage
          storage = upload.storage || ::PlaceOS::Model::Storage.storage_or_default(authority.id)
          signer = UploadSigner.signer(UploadSigner::StorageType.from_value(storage.storage_type.value), storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
          signer.delete_file(storage.bucket_name, upload.object_key, upload.resumable_id)
          upload.destroy
        end
        item.destroy
      end
    end
  end
end
