require "./application"

module PlaceOS::Api
  class Playlist < Application
    include Utils::Permissions

    base "/api/engine/v2/playlists"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_playlist(id : String)
      Log.context.set(playlist_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_playlist = playlist = Model::Playlist.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == playlist.authority_id
    end

    getter! current_playlist : Model::Playlist

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :playlist_update)]
    def parse_update_playlist(@playlist_update : Model::Playlist)
    end

    getter! playlist_update : Model::Playlist

    getter authority : Model::Authority { current_authority.as(Model::Authority) }

    # Permissions
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:destroy, :update, :create])]
    def check_access_level
      return if user_support?

      # find the org zone
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      access = check_access(current_user.groups, [org_zone_id])
      return if access.can_manage?

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list media playlists uploaded for this domain
    @[AC::Route::GET("/")]
    def index : Array(Model::Playlist)
      elastic = Model::Playlist.elastic
      query = elastic.query(search_params)
      query.filter({
        "authority_id" => [authority.id.as(String)],
      })
      query.search_field "name"
      query.sort({"created_at" => {order: :desc}})
      paginate_results(elastic, query)
    end

    # return the details of the requested media playlist
    @[AC::Route::GET("/:id")]
    def show : Model::Playlist
      current_playlist
    end

    # update the details of a media playlist
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : Model::Playlist
      playlist = playlist_update
      current = current_playlist
      current.assign_attributes(playlist)
      current.authority_id = authority.id
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new media playlist
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : Model::Playlist
      playlist = playlist_update
      playlist.authority_id = authority.id
      raise Error::ModelValidation.new(playlist.errors) unless playlist.save
      playlist
    end

    # remove a media playlist from the library
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_playlist.destroy
    end
  end
end
