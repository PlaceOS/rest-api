require "placeos-models/history"

module PlaceOS::Api
  # Resolve recorded ownership before pagination, including records which
  # have been deleted. Current ownership wins over older delete snapshots.
  module Utils::HistoryScope
    # Mask old records too: their snapshots may predate model-level redaction.
    def history_view(entry : ::PlaceOS::Model::History) : ::PlaceOS::Model::History
      redacted = {% begin %}
        case entry.resource_type
        {% for model in ::PlaceOS::Model::History::Tracked.includers %}
          when {{ model }}.table_name then {{ model }}.history_redacted
        {% end %}
        else [] of String
        end
      {% end %}
      redacted = redacted + ["webhook_secret"] if entry.resource_type == "trig"
      unless redacted.empty?
        diff = entry.diff.as_h.dup
        redacted.each do |field|
          diff[field] = JSON::Any.new([::PlaceOS::Model::History::Tracked::REDACTED, ::PlaceOS::Model::History::Tracked::REDACTED]) if diff.has_key?(field)
        end
        entry.diff = JSON::Any.new(diff)
        if snapshot = entry.snapshot.try(&.as_h?)
          entry.snapshot = JSON::Any.new(snapshot.reject { |field, _| redacted.includes?(field) })
        end
      end
      entry
    end

    def platform_history? : Bool
      !Utils::Tenancy.enforce? || (self.class.name == "PlaceOS::Api::History" && accessible_tenancy.cluster? && !query_params["organisation_id"]?)
    end

    private def history_owner_expression(table : String, id : String, column : String) : String
      <<-SQL
        (CASE WHEN EXISTS (SELECT 1 FROM "#{table}" owner_row WHERE owner_row.id::text = (#{id}))
          THEN (SELECT owner_row."#{column}"::text FROM "#{table}" owner_row WHERE owner_row.id::text = (#{id}))
          ELSE (SELECT owner_history.snapshot->>'#{column}' FROM history owner_history
            WHERE owner_history.resource_type = '#{table}' AND owner_history.resource_id = (#{id})
              AND owner_history.action = 'delete' AND owner_history.snapshot IS NOT NULL
            ORDER BY owner_history.created_at DESC, owner_history.id DESC LIMIT 1)
        END)
        SQL
    end

    private def history_authority_expression(table : String) : String?
      id = "history.resource_id"
      case table
      when "asset_type"
        category = history_owner_expression(table, id, "category_id")
        history_owner_expression("asset_category", category, "authority_id")
      when "asset"
        type = history_owner_expression(table, id, "asset_type_id")
        category = history_owner_expression("asset_type", type, "category_id")
        history_owner_expression("asset_category", category, "authority_id")
      when "alert"
        dashboard = history_owner_expression(table, id, "alert_dashboard_id")
        history_owner_expression("alert_dashboard", dashboard, "authority_id")
      when "playlist_items", "playlist_item_schedules", "playlist_revisions"
        playlist = history_owner_expression(table, id, "playlist_id")
        history_owner_expression("playlists", playlist, "authority_id")
      end
    end

    private def append_history_owner(clauses : Array(String), args : Array(String), table : String, expression : String, ids : Array(String))
      return if ids.empty?
      clauses << "(history.resource_type = '#{table}' AND (#{expression}) IN (#{ids.join(", ") { "?" }}))"
      args.concat(ids)
    end

    private def append_history_authority(clauses : Array(String), args : Array(String), table : String, expression : String, authorities : Array(String), organisations : Array(String))
      append_history_owner(clauses, args, table, expression, authorities)
      unless organisations.empty?
        owner = history_owner_expression("authority", expression, "organisation_id")
        append_history_owner(clauses, args, table, owner, organisations)
      end
    end

    def scope_history(query, required : ::PlaceOS::Model::Permissions = ::PlaceOS::Model::Permissions::Read)
      return query if platform_history?
      organisations = (permitted_organisation_ids(required) || Set(UUID).new).to_a.map(&.to_s)
      authorities = reachable_authority_ids(required) || [] of String
      clauses = [] of String
      args = [] of String
      {% for model in ::PlaceOS::Model::History::Tracked.includers %}
        %table = {{ model }}.table_name
        {% if model.has_method?(:organisation_id) %}
          %owner = history_owner_expression(%table, "history.resource_id", "organisation_id")
          append_history_owner(clauses, args, %table, %owner, organisations)
          {% if model == ::PlaceOS::Model::Authority %}
            %authority = history_owner_expression(%table, "history.resource_id", "id")
            append_history_owner(clauses, args, %table, %authority, authorities)
          {% end %}
        {% elsif model == ::PlaceOS::Model::Organisation %}
          %owner = history_owner_expression(%table, "history.resource_id", "id")
          append_history_owner(clauses, args, %table, %owner, organisations)
        {% elsif model.has_method?(:authority_id) %}
          %authority = history_owner_expression(%table, "history.resource_id", "authority_id")
          append_history_authority(clauses, args, %table, %authority, authorities, organisations)
        {% elsif model.has_method?(:group_id) %}
          %group = "COALESCE(history.correlation_id, history.snapshot->>'group_id')"
          %authority = history_owner_expression("groups", %group, "authority_id")
          append_history_authority(clauses, args, %table, %authority, authorities, organisations)
        {% elsif model.has_method?(:control_system_id) %}
          %system = history_owner_expression(%table, "history.resource_id", "control_system_id")
          %owner = history_owner_expression("sys", %system, "organisation_id")
          append_history_owner(clauses, args, %table, %owner, organisations)
        {% else %}
          if %authority = history_authority_expression(%table)
            append_history_authority(clauses, args, %table, %authority, authorities, organisations)
          end
        {% end %}
      {% end %}
      clauses.empty? ? query.where("1 = ?", 0) : query.where(clauses.join(" OR "), args)
    end

    def ensure_history_reach!(entry : ::PlaceOS::Model::History, required : ::PlaceOS::Model::Permissions = ::PlaceOS::Model::Permissions::Read)
      return if platform_history?
      query = ::PlaceOS::Model::History.where(id: entry.id)
      raise Error::NotFound.new("history not found") unless scope_history(query).first?
      raise Error::Forbidden.new("missing #{required} permission") unless scope_history(query, required).first?
    end
  end
end
