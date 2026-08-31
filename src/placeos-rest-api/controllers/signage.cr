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

      # the signage templates applied to this display or its zones
      template_mappings = signage_template_mappings(system)
      # the latest approved template or template schedule time
      if templates_last_updated = templates_last_updated(template_mappings)
        last_updated = templates_last_updated if templates_last_updated > last_updated
      end

      if !preview
        # Save last seen and currently playing item
        item_id = item_id.presence
        if item_id
          item = ::PlaceOS::Model::Playlist::Item.find(item_id) rescue nil
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

        # get the playlist configuration (default timeouts etc) and media lists (latest revisions)
        if playlist_ids.empty?
          playlist_details = [] of ::PlaceOS::Model::Playlist
          playlist_items = [] of ::PlaceOS::Model::Playlist::Revision
        else
          playlist_details = ::PlaceOS::Model::Playlist.where(id: playlist_ids).to_a
          playlist_items = ::PlaceOS::Model::Playlist::Revision.revisions(playlist_ids)
        end

        # distribution playlists schedule each item individually. To keep the
        # response format unchanged for existing players, every item schedule is
        # expanded into its own virtual single-item playlist (keyed by the
        # ItemSchedule id), and the distribution playlist id is swapped for those
        # virtual ids in the source => playlist mappings.
        distribution_ids = playlist_details.select(&.distribution).map(&.id.as(String)).to_set
        schedule_ids = distribution_ids.empty? ? [] of String : playlist_items.select { |rev| distribution_ids.includes?(rev.playlist_id.as(String)) }.flat_map(&.items).uniq!
        schedules_by_id = schedule_ids.empty? ? {} of String => ::PlaceOS::Model::Playlist::ItemSchedule : ::PlaceOS::Model::Playlist::ItemSchedule.where(id: schedule_ids).to_a.index_by { |schedule| schedule.id.as(String) }

        playlist_config = Hash(String, Tuple(::PlaceOS::Model::Playlist, Array(String))).new(playlist_details.size) { raise "no default" }
        # distribution playlist id => ordered virtual (item schedule) playlist ids
        expansion = Hash(String, Array(String)).new

        playlist_details.each do |playlist|
          playlist_id = playlist.id.as(String)
          items = playlist_items.find { |rev| rev.playlist_id == playlist_id }.try(&.items) || [] of String

          if playlist.distribution
            expansion[playlist_id] = items
            items.each do |schedule_id|
              schedule = schedules_by_id[schedule_id]?
              next unless schedule
              media_id = schedule.item_id
              playlist_config[schedule_id] = {virtual_playlist(playlist, schedule), media_id ? [media_id] : [] of String}
            end
          else
            playlist_config[playlist_id] = {playlist, items}
          end
        end

        # rewrite the mappings so distribution playlists resolve to their
        # per-item virtual playlists (order preserved)
        unless expansion.empty?
          playlist_map = playlist_map.transform_values do |ids|
            ids.flat_map { |id| expansion[id]? || [id] }
          end
        end

        system.playlist_mappings = playlist_map
        system.playlist_config = playlist_config
        template_mappings = resolve_default_template(template_mappings)
        system.signage_template_schedules = SignageTemplateMappings.hydrate!(template_mappings)

        # grab all the media details that should be cached / used in the media lists
        media_ids = playlist_config.values.flat_map(&.[](1)).uniq!

        media_details = media_ids.empty? ? [] of ::PlaceOS::Model::Playlist::Item : ::PlaceOS::Model::Playlist::Item.where(id: media_ids).to_a
        system.playlist_media = media_details

        # the plugins required to render the media and any template widgets
        plugin_ids = media_details.compact_map(&.plugin_id)
        template_mappings.each do |mapping|
          next unless template = mapping.template_details
          plugin_ids.concat template.layouts.compact_map(&.plugin_id)
        end
        plugin_ids.uniq!
        unless plugin_ids.empty?
          system.signage_plugins = ::PlaceOS::Model::SignagePlugin.where(id: plugin_ids).to_a
        end

        # ensure response caching is configured correctly
        response.headers["Cache-Control"] = "no-cache"
        system
      end
    end

    # Builds a virtual single-item playlist for one of a distribution playlist's
    # item schedules. The ItemSchedule id becomes the playlist id and the
    # schedule's own schedules drive playback, so the serialized shape is
    # identical to a regular scheduling playlist.
    private def virtual_playlist(playlist : ::PlaceOS::Model::Playlist, schedule : ::PlaceOS::Model::Playlist::ItemSchedule) : ::PlaceOS::Model::Playlist
      virtual = ::PlaceOS::Model::Playlist.new(
        name: playlist.name,
        description: playlist.description,
        authority_id: playlist.authority_id,
        orientation: playlist.orientation,
        play_count: playlist.play_count,
        play_through_count: playlist.play_through_count,
        default_animation: playlist.default_animation,
        random: playlist.random,
        enabled: playlist.enabled,
        default_duration: playlist.default_duration,
        valid_from: playlist.valid_from,
        valid_until: playlist.valid_until,
        # the schedule id is the virtual playlist id and it plays a single item
        # on its own schedule, so it is no longer a distribution container
        distribution: false,
        schedules: schedule.schedules,
      )
      virtual.id = schedule.id
      virtual.created_at = playlist.created_at
      virtual.updated_at = playlist.updated_at
      virtual
    end

    # the template mappings that apply to this display — applied directly or
    # via one of its zones. Only approved templates are shown on displays:
    # pending edits are staged on separate draft rows (which are never mapped)
    # and a never-approved template is its own unapproved version
    private def signage_template_mappings(system : ::PlaceOS::Model::ControlSystem) : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)
      zones_sql = ::PlaceOS::Model::Associations.format_list_for_postgres(system.zones)
      ::PlaceOS::Model::SignageTemplate::SystemTemplate.where(
        "(control_system_id = ? OR zone_id = ANY(#{zones_sql})) AND template_id IN (SELECT id FROM signage_template WHERE approved = true)",
        system.id.as(String)
      ).to_a
    end

    # only one default template (a mapping without a schedule) applies to a
    # display. Priority: mapped directly to the system, then the default on
    # the most specific (deepest / most child) zone, breaking ties with the
    # older zone and finally the older mapping
    private def resolve_default_template(mappings : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)) : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)
      defaults = mappings.select(&.default?)
      return mappings if defaults.size <= 1

      epoch = Time.unix(0)
      direct = defaults.select(&.control_system_id.presence)
      winner = if direct.empty?
                 depths = zone_depths(defaults.compact_map(&.zone_id.presence).uniq!)
                 defaults.min_by do |mapping|
                   depth, zone_created = depths[mapping.zone_id.as(String)]? || {0, epoch}
                   {-depth, zone_created, mapping.created_at || epoch}
                 end
               else
                 direct.min_by { |mapping| mapping.created_at || epoch }
               end

      mappings.reject { |mapping| mapping.default? && !mapping.same?(winner) }
    end

    # depth (ancestor count) and creation time of each of the provided zones,
    # resolved in a single recursive query over the parent chains
    private def zone_depths(zone_ids : Array(String)) : Hash(String, Tuple(Int32, Time))
      return {} of String => Tuple(Int32, Time) if zone_ids.empty?

      zones_sql = ::PlaceOS::Model::Associations.format_list_for_postgres(zone_ids)
      query = <<-SQL
        WITH RECURSIVE ancestry AS (
          SELECT id, parent_id, 0 AS depth
          FROM zone
          WHERE id = ANY(#{zones_sql})

          UNION ALL

          SELECT a.id, z.parent_id, a.depth + 1
          FROM zone z
          INNER JOIN ancestry a ON z.id = a.parent_id
        )
        SELECT a.id, MAX(a.depth), z.created_at
        FROM ancestry a
        INNER JOIN zone z ON z.id = a.id
        GROUP BY a.id, z.created_at
        SQL

      depths = {} of String => Tuple(Int32, Time)
      ::PgORM::Database.connection do |db|
        db.query_all(query) do |rs|
          depths[rs.read(String)] = {rs.read(Int32), rs.read(Time)}
        end
      end
      depths
    end

    # the most recent change to an applied template or its schedule
    private def templates_last_updated(mappings : Array(::PlaceOS::Model::SignageTemplate::SystemTemplate)) : Time?
      return nil if mappings.empty?

      times = mappings.compact_map(&.updated_at)
      template_ids = mappings.map(&.template_id).uniq!
      template_updated = ::PlaceOS::Model::SignageTemplate
        .where(id: template_ids)
        .order(updated_at: :desc)
        .limit(1).to_a.first?.try(&.updated_at)
      times << template_updated if template_updated
      times.max?
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
