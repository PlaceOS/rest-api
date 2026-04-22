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
    def display(
      system_id : String,
      @[AC::Param::Info(description: "currently playing item, if the player is playing content", example: "playlist_items-1234")]
      item_id : String? = nil,
      @[AC::Param::Info(description: "is this the preview player", example: "true")]
      preview : Bool = true,
    ) : ::PlaceOS::Model::ControlSystem?
      # grab all the playlists associated with the display and check if anything has changed
      system = ::PlaceOS::Model::ControlSystem.find!(system_id)
      playlist_map = system.all_playlists
      last_updated = system.playlists_last_updated(playlist_map)

      if !preview
        # Save last seen and currently playing item
        if item_id
          item = ::PlaceOS::Model::Playlist::Item.find(item_id)
          item_id = nil unless item
        end

        # this update is less important than fetching content
        begin
          system.update_last_seen_time(item_id)
        rescue error
          Log.error(exception: error) { "error storing last seen" }
        end
      end

      # continue processing the request if the client has stale data
      if stale?(last_modified: last_updated)
        playlist_ids = playlist_map.values.flatten.uniq!
        system.playlist_mappings = playlist_map

        # get the playlist configuration (default timeouts etc) and media lists (latest revisions)
        if playlist_ids.empty?
          playlist_details = [] of ::PlaceOS::Model::Playlist
          playlist_items = [] of ::PlaceOS::Model::Playlist::Revision
        else
          playlist_details = ::PlaceOS::Model::Playlist.where(id: playlist_ids).to_a
          playlist_items = ::PlaceOS::Model::Playlist::Revision.revisions(playlist_ids)
        end

        playlist_config = Hash(String, Tuple(::PlaceOS::Model::Playlist, Array(String))).new(playlist_details.size) { raise "no default" }
        playlist_details.each do |playlist|
          items = playlist_items.find { |rev| rev.playlist_id == playlist.id }.try(&.items) || [] of String
          playlist_config[playlist.id.as(String)] = {playlist, items}
        end

        system.playlist_config = playlist_config

        # grab all the media details that should be cached / used in the media lists
        media_ids = playlist_config.values.flat_map(&.[](1)).uniq!

        if media_ids.empty?
          system.playlist_media = [] of ::PlaceOS::Model::Playlist::Item
        else
          media_details = ::PlaceOS::Model::Playlist::Item.where(id: media_ids).to_a
          system.playlist_media = media_details

          plugin_ids = media_details.compact_map(&.plugin_id).uniq!
          if !plugin_ids.empty?
            system.signage_plugins = ::PlaceOS::Model::SignagePlugin.where(id: plugin_ids).to_a
          end
        end

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
