require "./signage/*"
require "./application"

module PlaceOS::Api
  class Signage < Application
    include Utils::Permissions

    base "/api/engine/v2/signage"

    # Permissions
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:update_metrics])]
    def check_access_level
      raise Error::Forbidden.new unless user_support?
    end

    ###############################################################################################

    # return all the details for displaying signage
    @[AC::Route::GET("/:system_id")]
    def display(system_id : String) : ::PlaceOS::Model::ControlSystem?
      # grab all the playlists associated with the display and check if anything has changed
      system = ::PlaceOS::Model::ControlSystem.find!(system_id)
      playlist_map = system.all_playlists
      last_updated = system.playlists_last_updated(playlist_map)

      # continue processing the request if the client has stale data
      if stale?(last_modified: last_updated)
        playlist_ids = playlist_map.values.flatten.uniq!
        system.playlist_mappings = playlist_map

        # get the playlist configuration (default timeouts etc) and media lists (latest revisions)
        playlist_details = ::PlaceOS::Model::Playlist.where(id: playlist_ids).to_a
        playlist_items = ::PlaceOS::Model::Playlist::Revision.revisions(playlist_ids)

        playlist_config = Hash(String, Tuple(::PlaceOS::Model::Playlist, Array(String))).new(playlist_details.size) { raise "no default" }
        playlist_details.each do |playlist|
          items = playlist_items.find { |rev| rev.playlist_id == playlist.id }.try(&.items) || [] of String
          playlist_config[playlist.id.as(String)] = {playlist, items}
        end

        system.playlist_config = playlist_config

        # grab all the media details that should be cached / used in the media lists
        media_ids = playlist_config.values.flat_map(&.[](1)).uniq!
        system.playlist_media = ::PlaceOS::Model::Playlist::Item.where(id: media_ids).to_a

        # ensure response caching is configured correctly
        response.headers["Cache-Control"] = "no-cache"
        system
      end
    end

    struct Metrics
      include JSON::Serializable

      getter play_through_counts : Hash(String, Int32)
      getter playlist_counts : Hash(String, Int32)
      getter media_counts : Hash(String, Int32)
    end

    # update the metrics for production players
    @[AC::Route::POST("/:system_id/metrics", body: :metrics, status_code: HTTP::Status::ACCEPTED)]
    def update_metrics(system_id : String, metrics : Metrics) : Nil
      Log.context.set(system_id: system_id)
      ::PlaceOS::Model::Playlist::Item.update_counts(metrics.media_counts)
      ::PlaceOS::Model::Playlist.update_counts(metrics.playlist_counts)
      ::PlaceOS::Model::Playlist.update_through_counts(metrics.play_through_counts)
    end
  end
end
