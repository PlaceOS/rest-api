require "upload-signer"
require "uuid"
require "placeos-models/group/playlist_item"

require "../application"

module PlaceOS::Api
  class PlaylistMedia < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/signage/media"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :tags]
    before_action :can_write, only: [:create, :update, :destroy, :share]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :tags, :create, :share])]
    def current_item(id : String)
      Log.context.set(item_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_item = item = ::PlaceOS::Model::Playlist::Item.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == item.authority_id
    end

    getter! current_item : ::PlaceOS::Model::Playlist::Item

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :item_update)]
    def parse_update_item(@item_update : ::PlaceOS::Model::Playlist::Item)
    end

    getter! item_update : ::PlaceOS::Model::Playlist::Item

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

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

    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_destroy_access
      enforce_item_access!(&.delete?)
    end

    ###############################################################################################

    # Resolve which groups bound the caller's visibility, honoring
    # `group_id`. We key access off the *bounded* set of group ids (a user
    # belongs to tens of groups) rather than the *unbounded* set of item
    # ids — the actual item filter is pushed into SQL as a subquery against
    # the `group_playlist_items` junction, so item ids are never pulled
    # into memory.
    #
    # Returns:
    # - `nil`  => no group constraint (admin/support: all authority media)
    # - `[]`   => caller can see nothing (short-circuit to an empty result)
    # - `[..]` => constrain to items linked to any of these groups
    private def accessible_group_scope(group_id : UUID?) : Array(UUID)?
      if group_id
        unless user_support?
          perms = group_memberships(current_user)[group_id]? || ::PlaceOS::Model::Permissions::None
          raise Error::Forbidden.new unless perms.read?
        end
        return [group_id]
      end

      # admin/support see every item in the authority — no group constraint
      return nil if user_support?

      group_memberships(current_user).compact_map do |g_id, g_perms|
        g_id if g_perms.read?
      end
    end

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
    # group; `q=...` is a case-insensitive substring search across
    # `name` and `description`; `tags=...` returns items carrying any of
    # the supplied tags.
    @[AC::Route::GET("/", converters: {tags: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "filter to items linked to this group (caller must have Read on the group)")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "case-insensitive substring search on name and description (SQL ILIKE)")]
      q : String? = nil,
      @[AC::Param::Info(description: "return items carrying any of these tags", example: "promo,lobby")]
      tags : Array(String)? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::Playlist::Item)
      query = ::PlaceOS::Model::Playlist::Item.where(authority_id: authority.id.as(String))

      scope = accessible_group_scope(group_id)
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

      paginate_sql(query, type: "playlist_items", limit: limit, offset: offset)
    end

    # return the distinct tags in use by media. Scopes the same way as
    # `index`: `group_id=...` limits to media linked to that group (caller
    # must have Read on it); without `group_id`, admin/support callers see
    # every tag in the authority while regular users see tags from media in
    # groups they can read.
    @[AC::Route::GET("/tags")]
    def tags(
      @[AC::Param::Info(description: "limit to media linked to this group (caller must have Read on the group)")]
      group_id : UUID? = nil,
    ) : Array(String)
      scope = accessible_group_scope(group_id)
      return [] of String if !scope.nil? && scope.empty?

      # Distinct tags computed in SQL — we never materialize item ids. The
      # optional group scope is a subquery against the junction table, keyed
      # on the bounded `group_id = ANY($2)` array.
      sql = String.build do |str|
        str << "SELECT DISTINCT unnest(tags) AS tag FROM playlist_items WHERE authority_id = $1"
        str << " AND id IN (SELECT playlist_item_id FROM group_playlist_items WHERE group_id = ANY($2::uuid[]))" unless scope.nil?
        str << " ORDER BY tag"
      end

      PgORM::Database.connection do |db|
        if scope.nil?
          db.query_all(sql, args: [authority.id.as(String)], as: String)
        else
          db.query_all(sql, args: [authority.id.as(String), scope.map(&.to_s)], as: String)
        end
      end
    end

    # return the details of the requested media item
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Playlist::Item
      current_item
    end

    # redirects to the thumbnail image URL
    @[AC::Route::GET("/:id/thumbnail")]
    def thumbnail
      raise Error::NotFound.new("no thumbnail associated") unless current_item.thumbnail_id
      current_upload = current_item.thumbnail.as(::PlaceOS::Model::Upload)

      unless storage = current_upload.storage
        Log.warn { {message: "upload object associated storage not found", upload_id: current_upload.id, authority: authority.id, user: current_user.id} }
        raise Error::NotFound.new("Upload #{current_upload.id} missing associated storage")
      end

      us = UploadSigner.signer(UploadSigner::StorageType.from_value(storage.storage_type.value), storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
      object_url = us.get_object(storage.bucket_name, current_upload.object_key, 60)

      redirect_to object_url, status: :see_other
    end

    # update the details of a media item
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::Playlist::Item
      item = item_update
      current = current_item
      current.assign_attributes(item)
      current.authority_id = authority.id
      raise Error::ModelValidation.new(current.errors) unless current.save
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

    # remove a media item from the library
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      PgORM::Database.transaction do |_tx|
        {current_item.media, current_item.thumbnail}.each do |upload|
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
        current_item.destroy
      end
    end
  end
end
