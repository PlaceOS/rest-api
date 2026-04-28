require "uuid"
require "placeos-models/group/playlist"

require "../application"

module PlaceOS::Api
  class Playlist < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/signage/playlists"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :media, :media_revisions]
    before_action :can_write, only: [:create, :update, :destroy, :update_media, :approve_media]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_playlist(id : String)
      Log.context.set(playlist_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_playlist = playlist = ::PlaceOS::Model::Playlist.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == playlist.authority_id
    end

    getter! current_playlist : ::PlaceOS::Model::Playlist

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :playlist_update)]
    def parse_update_playlist(@playlist_update : ::PlaceOS::Model::Playlist)
    end

    getter! playlist_update : ::PlaceOS::Model::Playlist

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

    # Permissions
    ###############################################################################################
    #
    # Access model:
    # - sys_admin / support users bypass all checks (`user_support?`
    #   already includes admin).
    # - Regular users get access via groups carrying the "signage"
    #   subsystem: each action requires the matching Permissions bit on
    #   at least one group the playlist is linked to (via GroupPlaylist)
    #   that the user is a member of.
    # - A playlist with no GroupPlaylist rows is admin/support-only.

    # Groups this playlist is linked to — memoised per controller
    # instance so multiple guards share the same query.
    private def linked_playlist_groups : Array(UUID)
      @linked_playlist_groups ||= ::PlaceOS::Model::GroupPlaylist
        .where(playlist_id: current_playlist.id)
        .to_a
        .map(&.group_id)
    end

    @linked_playlist_groups : Array(UUID)? = nil

    private def enforce_playlist_access!(&block : ::PlaceOS::Model::Permissions -> Bool)
      return if user_support?
      raise Error::Forbidden.new if linked_playlist_groups.empty?
      perms = effective_permissions_for(current_user, linked_playlist_groups)
      raise Error::Forbidden.new unless block.call(perms)
    end

    @[AC::Route::Filter(:before_action, only: [:show, :media, :media_revisions])]
    def check_read_access
      enforce_playlist_access!(&.read?)
    end

    @[AC::Route::Filter(:before_action, only: [:update, :update_media])]
    def check_update_access
      enforce_playlist_access!(&.update?)
    end

    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_destroy_access
      enforce_playlist_access!(&.delete?)
    end

    @[AC::Route::Filter(:before_action, only: [:approve_media])]
    def check_approve_access
      enforce_playlist_access!(&.approve?)
    end

    ###############################################################################################

    # list media playlists in the current authority.
    #
    # Non-admin callers see only playlists linked to groups they're a
    # member of (direct or transitive). Pass `group_id=...` to scope to
    # a specific group (caller must have Read on that group). Pass
    # `q=...` for a case-insensitive substring search over `name` and
    # `description`.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter to playlists linked to this group (caller must have Read on the group)")]
      group_id : String? = nil,
      @[AC::Param::Info(description: "case-insensitive substring search on name and description (SQL ILIKE)")]
      q : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::Playlist)
      query = ::PlaceOS::Model::Playlist.where(authority_id: authority.id.as(String))

      if group_id
        gid = UUID.new(group_id)
        unless user_support?
          perms = group_memberships(current_user)[gid]? || ::PlaceOS::Model::Permissions::None
          raise Error::Forbidden.new unless perms.read?
        end
        linked_ids = ::PlaceOS::Model::GroupPlaylist
          .where(group_id: gid)
          .to_a
          .map(&.playlist_id)
        if linked_ids.empty?
          set_collection_headers(0, "playlists")
          return [] of ::PlaceOS::Model::Playlist
        end
        query = query.where(id: linked_ids)
      elsif !user_support?
        # Regular user with no group_id filter: scope to every playlist
        # linked to a group they have Read access on.
        viewable = group_memberships(current_user).compact_map do |gid, perms|
          gid if perms.read?
        end
        if viewable.empty?
          set_collection_headers(0, "playlists")
          return [] of ::PlaceOS::Model::Playlist
        end
        linked_ids = ::PlaceOS::Model::GroupPlaylist
          .where(group_id: viewable)
          .to_a
          .map(&.playlist_id)
          .uniq!
        if linked_ids.empty?
          set_collection_headers(0, "playlists")
          return [] of ::PlaceOS::Model::Playlist
        end
        query = query.where(id: linked_ids)
      end

      if (term = q) && !term.empty?
        pattern = "%#{term}%"
        query = query.where("(name ILIKE ? OR description ILIKE ?)", pattern, pattern)
      end

      paginate_sql(query, type: "playlists", limit: limit, offset: offset)
    end

    # return the details of the requested media playlist
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Playlist
      current_playlist
    end

    # update the details of a media playlist
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::Playlist
      playlist = playlist_update
      current = current_playlist
      current.assign_attributes(playlist)
      current.authority_id = authority.id
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new media playlist. Non-admin callers must supply `group_id`
    # and hold Create permission on that group — the playlist is
    # auto-linked to the group via a GroupPlaylist junction row so the
    # creator can see it immediately. Admin/support callers may omit
    # `group_id`, in which case the playlist is created unlinked
    # (admin-only visibility).
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create(
      @[AC::Param::Info(description: "group id to auto-link the new playlist to (required for non-admin callers)")]
      group_id : String? = nil,
    ) : ::PlaceOS::Model::Playlist
      playlist = playlist_update
      playlist.authority_id = authority.id

      target_gid = group_id.try { |g| UUID.new(g) }

      unless user_support?
        raise Error::Forbidden.new("group_id required") if target_gid.nil?
        perms = group_memberships(current_user)[target_gid]? || ::PlaceOS::Model::Permissions::None
        raise Error::Forbidden.new("missing Create permission on the target group") unless perms.create?
      end

      ::PgORM::Database.transaction do |_tx|
        raise Error::ModelValidation.new(playlist.errors) unless playlist.save
        if target_gid
          link = ::PlaceOS::Model::GroupPlaylist.new(
            group_id: target_gid,
            playlist_id: playlist.id.as(String),
          )
          raise Error::ModelValidation.new(link.errors) unless link.save
        end
      end

      playlist
    end

    # remove a media playlist from the library
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_playlist.destroy
    end

    # Playlist Revisions
    # ==================

    # get the current list of media for the playlist
    @[AC::Route::GET("/:id/media")]
    def media : ::PlaceOS::Model::Playlist::Revision
      media_revisions(1).first? || ::PlaceOS::Model::Playlist::Revision.new
    end

    # returns the previous versions of a playlist
    @[AC::Route::GET("/:id/media/revisions")]
    def media_revisions(limit : Int32 = 10) : Array(::PlaceOS::Model::Playlist::Revision)
      current_playlist.revisions.limit(limit).to_a
    end

    # provide an update list of media for a playlist
    @[AC::Route::POST("/:id/media", body: :items)]
    def update_media(items : Array(String)) : ::PlaceOS::Model::Playlist::Revision
      new_revision = ::PlaceOS::Model::Playlist::Revision.new
      new_revision.items = items
      new_revision.user = current_user
      new_revision.playlist_id = current_playlist.id
      raise Error::ModelValidation.new(new_revision.errors) unless new_revision.save
      new_revision
    end

    # approve a playlist for publication on displays
    @[AC::Route::POST("/:id/media/approve")]
    def approve_media : Bool
      revision = media_revisions(1).first?
      raise Error::NotFound.new("no media in playlist") unless revision

      revision.approver = current_user
      raise Error::ModelValidation.new(revision.errors) unless revision.save
      true
    end
  end
end
