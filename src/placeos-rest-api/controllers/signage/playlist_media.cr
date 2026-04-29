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

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
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

    # list media items for the current authority.
    #
    # Non-admin callers see only items linked to groups they're a member
    # of (direct or transitive). `group_id=...` scopes to a single
    # group; `q=...` is a case-insensitive substring search across
    # `name` and `description`.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter to items linked to this group (caller must have Read on the group)")]
      group_id : String? = nil,
      @[AC::Param::Info(description: "case-insensitive substring search on name and description (SQL ILIKE)")]
      q : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::Playlist::Item)
      query = ::PlaceOS::Model::Playlist::Item.where(authority_id: authority.id.as(String))

      if group_id
        gid = UUID.new(group_id)
        unless user_support?
          perms = group_memberships(current_user)[gid]? || ::PlaceOS::Model::Permissions::None
          raise Error::Forbidden.new unless perms.read?
        end
        linked_ids = ::PlaceOS::Model::GroupPlaylistItem
          .where(group_id: gid)
          .to_a
          .map(&.playlist_item_id)
        if linked_ids.empty?
          set_collection_headers(0, "playlist_items")
          return [] of ::PlaceOS::Model::Playlist::Item
        end
        query = query.where(id: linked_ids)
      elsif !user_support?
        viewable = group_memberships(current_user).compact_map do |g_id, g_perms|
          g_id if g_perms.read?
        end
        if viewable.empty?
          set_collection_headers(0, "playlist_items")
          return [] of ::PlaceOS::Model::Playlist::Item
        end
        linked_ids = ::PlaceOS::Model::GroupPlaylistItem
          .where(group_id: viewable)
          .to_a
          .map(&.playlist_item_id)
          .uniq!
        if linked_ids.empty?
          set_collection_headers(0, "playlist_items")
          return [] of ::PlaceOS::Model::Playlist::Item
        end
        query = query.where(id: linked_ids)
      end

      if (term = q) && !term.empty?
        pattern = "%#{term}%"
        query = query.where("(name ILIKE ? OR description ILIKE ?)", pattern, pattern)
      end

      paginate_sql(query, type: "playlist_items", limit: limit, offset: offset)
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
      group_id : String? = nil,
    ) : ::PlaceOS::Model::Playlist::Item
      item = item_update
      item.authority_id = authority.id

      target_gid = group_id.try { |g| UUID.new(g) }

      unless user_support?
        raise Error::Forbidden.new("group_id required") if target_gid.nil?
        perms = group_memberships(current_user)[target_gid]? || ::PlaceOS::Model::Permissions::None
        raise Error::Forbidden.new("missing Create permission on the target group") unless perms.create?
      end

      ::PgORM::Database.transaction do |_tx|
        raise Error::ModelValidation.new(item.errors) unless item.save
        if target_gid
          link = ::PlaceOS::Model::GroupPlaylistItem.new(
            group_id: target_gid,
            playlist_item_id: item.id.as(String),
          )
          raise Error::ModelValidation.new(link.errors) unless link.save
        end
      end

      item
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
