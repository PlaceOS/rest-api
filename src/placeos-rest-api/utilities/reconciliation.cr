require "digest/sha256"

module PlaceOS::Api::Utils
  # Explicit platform ownership maintenance; ordinary resource CRUD stays scoped.
  class Reconciliation
    OWNED           = %w[authority zone sys mod trigger edge broker]
    NAMED           = %w[zone sys edge broker]
    MAX_ROWS        =   5000
    MAX_FIELD_BYTES = 65_536
    SAMPLE_SIZE     =     20
    SNAPSHOT_FIELDS = {
      "authority"      => %w[id organisation_id domain config],
      "zone"           => %w[id organisation_id name parent_id],
      "sys"            => %w[id organisation_id name zones modules],
      "mod"            => %w[id organisation_id control_system_id edge_id],
      "trigger"        => %w[id organisation_id control_system_id],
      "edge"           => %w[id organisation_id name user_id api_key_id],
      "broker"         => %w[id organisation_id name],
      "organisations"  => %w[id partner_id partner_staff],
      "partners"       => %w[id management],
      "user"           => %w[id authority_id sys_admin support deleted groups],
      "api_key"        => %w[id user_id authority_id permissions scopes expires_at],
      "grants"         => %w[id user_id scope_type scope_id permissions expires_at],
      "groups"         => %w[id authority_id parent_id subsystems],
      "group_zones"    => %w[group_id zone_id permissions deny],
      "pending_mail"   => %w[id authority_id zones],
      "asset"          => %w[id asset_type_id zone_id zones],
      "asset_type"     => %w[id category_id],
      "asset_category" => %w[id authority_id],
      "trig"           => %w[id control_system_id trigger_id zone_id],
    }

    record Operation, kind : String, resource_type : String? = nil,
      resource_ids : Array(String) = [] of String,
      source_organisation_id : UUID? = nil, target_organisation_id : UUID? = nil do
      include JSON::Serializable
    end

    record Change, resource_type : String, resource_id : String,
      source_organisation_id : String?, target_organisation_id : String do
      include JSON::Serializable
    end

    record Blocker, code : String, resource_type : String?, resource_id : String?, message : String do
      include JSON::Serializable
    end

    record AccessChange, authority_id : String, source_organisation_id : String?, target_organisation_id : String,
      users_affected : Int32, api_keys_affected : Int32,
      user_sample : Array(String), api_key_sample : Array(String), active_administrators : Int32,
      active_support : Int32, sample_complete : Bool do
      include JSON::Serializable
    end

    record GrantChange, grant_id : String, user_id : String, source_scope_id : String, target_scope_id : String,
      permissions : Int32, expires_at : String? do
      include JSON::Serializable
    end

    record TargetGrantEffect, scope_type : String, scope_id : String, grants_affected : Int32,
      user_sample : Array(String), sample_complete : Bool do
      include JSON::Serializable
    end

    record Preview, digest : String, operations : Array(Operation), changes : Array(Change),
      blockers : Array(Blocker), retained_organisations : Array(String),
      access_changes : Array(AccessChange), grant_changes : Array(GrantChange), warnings : Array(String),
      target_grant_effects : Array(TargetGrantEffect) do
      include JSON::Serializable
    end

    record Result, id : String, digest : String, changes : Array(Change), retained_organisations : Array(String),
      access_changes : Array(AccessChange), grant_changes : Array(GrantChange), target_grant_effects : Array(TargetGrantEffect) do
      include JSON::Serializable
    end

    def self.canonical(value : JSON::Any) : String
      case raw = value.raw
      when Hash
        "{" + raw.keys.sort!.map { |key| "#{key.to_json}:#{canonical(raw[key])}" }.join(',') + "}"
      when Array
        "[" + raw.map { |item| canonical(item) }.join(',') + "]"
      else
        raw.to_json
      end
    end

    def self.preview(operations : Array(Operation)) : Preview
      result = nil.as(Preview?)
      PgORM::Database.transaction do |tx|
        tx.connection.exec("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", args: [] of String)
        result = Builder.new(operations).build
      end
      result.not_nil!
    end

    def self.apply(operations : Array(Operation), digest : String, key : String, actor_id : String, authority_id : String, api_key_id : String?, &authorize : -> Nil) : JSON::Any
      raise Error::OrganisationSelection.new("provide an idempotency key of at most 128 characters", "invalid_idempotency_key") if key.empty? || key.bytesize > 128
      result = nil.as(JSON::Any?)
      PgORM::Database.transaction do |tx|
        db = tx.connection
        db.exec("SELECT pg_advisory_xact_lock(hashtext($1))", args: ["placeos:reconciliation"])
        authorize.call
        request = JSON.parse(operations.to_json)
        previous = db.query_one?("SELECT digest, plan::text, result::text FROM tenancy_reconciliations WHERE actor_id = $1 AND idempotency_key = $2",
          args: [actor_id, key], as: {String, String, String})
        if previous
          stored = JSON.parse(previous[1])
          stored_operations = stored.as_a? ? stored : stored["operations"]
          unless previous[0] == digest && canonical(stored_operations) == canonical(request)
            raise Error::Conflict.new("idempotency key was already used for another plan")
          end
          result = JSON.parse(previous[2])
          next
        end
        operations.flat_map { |op| [op.source_organisation_id, op.target_organisation_id].compact.map(&.to_s) }.uniq!.sort!.each do |owner|
          db.exec("SELECT pg_advisory_xact_lock(hashtext($1))", args: ["placeos:organisation-admin:#{owner}"])
        end
        # Array references have no FK locks. Prevent new memberships while
        # checking the preview and applying its bounded dependency closure.
        db.exec(%(LOCK TABLE authority, zone, sys, mod, "trigger", edge, broker, grants, organisations, partners, "user", api_key, groups, group_zones, pending_mail, asset, asset_type, asset_category, trig IN SHARE ROW EXCLUSIVE MODE), args: [] of String)
        authorize.call
        current = Builder.new(operations).build
        raise Error::Conflict.new("ownership or references changed; obtain a new preview") unless current.digest == digest
        raise Error::Conflict.new("resolve the preview blockers before applying") unless current.blockers.empty?
        current.changes.each do |change|
          db.exec(%(UPDATE "#{change.resource_type}" SET organisation_id = $1::uuid WHERE id = $2), args: [change.target_organisation_id, change.resource_id])
          ::PlaceOS::Model::History.record_change(change.resource_type, change.resource_id, "update",
            diff: {"organisation_id" => JSON::Any.new([JSON::Any.new(change.source_organisation_id), JSON::Any.new(change.target_organisation_id)])})
        end
        current.grant_changes.each do |grant|
          updated = db.exec("UPDATE grants SET scope_id = $1 WHERE id = $2::uuid AND scope_type = 'organisation' AND scope_id = $3",
            args: [grant.target_scope_id, grant.grant_id, grant.source_scope_id])
          raise Error::Conflict.new("reviewed grant changed; obtain a new preview") unless updated.rows_affected == 1
          ::PlaceOS::Model::History.record_change("grants", grant.grant_id, "update", correlation_id: grant.target_scope_id,
            diff: {"scope_id" => JSON::Any.new([JSON::Any.new(grant.source_scope_id), JSON::Any.new(grant.target_scope_id)])})
        end
        id = db.query_one("SELECT uuidv7()::text", args: [] of String, &.read(String))
        value = Result.new(id, digest, current.changes, current.retained_organisations, current.access_changes, current.grant_changes, current.target_grant_effects)
        # No source organisation is deleted: its name/configuration remain
        # available for review, even after all ownership has been consolidated.
        db.exec(<<-SQL, args: [id, actor_id, authority_id, api_key_id, key, digest, current.to_json, value.to_json])
          INSERT INTO tenancy_reconciliations (id, actor_id, authority_id, api_key_id, idempotency_key, digest, plan, result)
          VALUES ($1::uuid, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb)
          SQL
        result = JSON.parse(value.to_json)
      end
      result.not_nil!
    end

    class Builder
      @rows = {} of String => JSON::Any
      @observations = [] of JSON::Any
      @changes = {} of String => Change
      @blockers = [] of Blocker
      @retained = [] of String
      @access = {} of String => AccessChange
      @grants = {} of String => GrantChange
      @target_grants = {} of String => TargetGrantEffect
      @queries = {} of String => Array(JSON::Any)
      @observed_rows = 0
      @snapshot_bytes = 0

      def initialize(@operations : Array(Operation))
      end

      def build : Preview
        if @operations.empty? || @operations.size > 50
          raise Error::OrganisationSelection.new("provide between one and 50 reconciliation operations", "invalid_operations")
        end
        validate_merge_graph
        @operations.each { |operation| expand(operation) }
        collect_target_grant_effects
        validate_grant_collisions
        validate_references
        validate_names
        validate_administrators
        changes = @changes.values.sort_by! { |change| {change.resource_type, change.resource_id} }
        blockers = @blockers.uniq.sort_by! { |item| {item.code, item.resource_type.to_s, item.resource_id.to_s} }
        fingerprint = JSON.parse({operations: @operations, observations: @observations, changes: changes, blockers: blockers}.to_json)
        digest = Digest::SHA256.hexdigest(Reconciliation.canonical(fingerprint))
        access = @access.values.sort_by!(&.authority_id)
        grants = @grants.values.sort_by!(&.grant_id)
        warnings = if access.empty? && grants.empty?
                     [] of String
                   else
                     ["Review changed home-organisation and grant reach across the combined estate before applying."]
                   end
        Preview.new(digest, @operations, changes, blockers, @retained.uniq.sort!, access, grants, warnings,
          @target_grants.values.sort_by! { |effect| {effect.scope_type, effect.scope_id} })
      end

      private def oversized! : NoReturn
        raise Error::OrganisationSelection.new("reconciliation snapshot exceeds its bounds; split the plan", "plan_too_large")
      end

      # Never load credentials, large descriptions, or unbounded reference arrays.
      private def projection(table : String) : String
        overflow = [] of String
        pairs = SNAPSHOT_FIELDS[table].map do |column|
          expression = case column
                       when "zones", "modules"
                         too_large = "COALESCE(cardinality(r.#{column}) > #{MAX_ROWS} OR octet_length(r.#{column}::text) > #{MAX_FIELD_BYTES}, false)"
                         overflow << too_large
                         "CASE WHEN #{too_large} THEN '[]'::jsonb ELSE to_jsonb(r.#{column}) END"
                       when "scopes", "groups", "subsystems"
                         too_large = "COALESCE(octet_length(r.#{column}::text) > #{MAX_FIELD_BYTES}, false)"
                         overflow << too_large
                         "CASE WHEN #{too_large} THEN '[]'::jsonb ELSE to_jsonb(r.#{column}) END"
                       when "config"
                         too_large = "COALESCE(octet_length(r.config->>'org_zone') > 4096, false)"
                         overflow << too_large
                         "jsonb_build_object('org_zone', CASE WHEN NOT (#{too_large}) AND jsonb_typeof(r.config->'org_zone') = 'string' THEN r.config->'org_zone' ELSE NULL END)"
                       when "name"
                         overflow << "COALESCE(octet_length(r.name) > 4096, false)"
                         "left(r.name, 4096)"
                       else
                         "r.#{column}"
                       end
          "'#{column}', #{expression}"
        end
        too_large = overflow.empty? ? "false" : overflow.join(" OR ")
        "jsonb_build_object(#{pairs.join(", ")}, '_overflow', #{too_large})::text"
      end

      private def observe(table : String, where : String = "TRUE", args : Array(String) = [] of String) : Array(JSON::Any)
        key = Reconciliation.canonical(JSON.parse({table: table, where: where, args: args}.to_json))
        if cached = @queries[key]?
          return cached
        end
        oversized! if @queries.size >= MAX_ROWS
        records = [] of JSON::Any
        order = table == "group_zones" ? "r.group_id, r.zone_id" : "r.id::text"
        remaining = MAX_ROWS - @observed_rows
        PgORM::Database.connection do |db|
          db.query_each(%(SELECT #{projection(table)} FROM "#{table}" r WHERE #{where} ORDER BY #{order} LIMIT #{remaining + 1}), args: args) do |rs|
            encoded = rs.read(String)
            @observed_rows += 1
            @snapshot_bytes += encoded.bytesize
            oversized! if @observed_rows > MAX_ROWS || @snapshot_bytes > 16 * 1024 * 1024
            value = JSON.parse(encoded)
            oversized! if value["_overflow"].as_bool
            if id = value["id"]?.try(&.as_s?)
              @rows["#{table}/#{id}"] = value
            end
            records << value
          end
        end
        @observations << JSON.parse({table: table, where: where, args: args, rows: records}.to_json)
        @queries[key] = records
      end

      private def row(table : String, id : String) : JSON::Any?
        if cached = @rows["#{table}/#{id}"]?
          return cached
        end
        observe(table, "r.id::text = $1", [id]).first?
      end

      private def validate_merge_graph
        merges = @operations.select(&.kind.==("merge_organisations"))
        sources = merges.compact_map(&.source_organisation_id)
        merges.each do |op|
          if sources.count(op.source_organisation_id) > 1 || sources.includes?(op.target_organisation_id)
            block("merge_overlap", "organisations", op.source_organisation_id.try(&.to_s), "merge sources must be distinct and cannot also be destinations")
          end
        end
      end

      private def collect_target_grant_effects
        @changes.values.map(&.target_organisation_id).uniq!.each do |id|
          next unless target = row("organisations", id)
          scopes = [{"organisation", id}]
          if partner = field(target, "partner_id")
            row("partners", partner)
            scopes << {"partner", partner}
          end
          scopes.each do |type, scope_id|
            held = observe("grants", "r.scope_type = $1 AND r.scope_id = $2", [type, scope_id])
            users = held.map(&.["user_id"].as_s).uniq!.sort!
            @target_grants["#{type}/#{scope_id}"] = TargetGrantEffect.new(type, scope_id, held.size, users.first(SAMPLE_SIZE), users.size <= SAMPLE_SIZE)
          end
        end
      end

      private def validate_grant_collisions
        held = @rows.select { |key, grant| key.starts_with?("grants/") && grant["scope_type"].as_s == "organisation" }.values
        held.group_by { |grant| {grant["user_id"].as_s, @grants[grant["id"].as_s]?.try(&.target_scope_id) || grant["scope_id"].as_s} }.each_value do |group|
          if group.size > 1
            block("grant_collision", "grants", group.first["id"].as_s, "resolve final grant permissions and expiry explicitly before merging")
          end
        end
      end

      private def field(value : JSON::Any, key : String) : String?
        value[key]?.try(&.as_s?).try(&.presence)
      end

      private def owner(value : JSON::Any) : String?
        field(value, "organisation_id")
      end

      private def ids(value : JSON::Any, key : String) : Array(String)
        values = value[key]?.try(&.as_a?) || [] of JSON::Any
        oversized! if values.size > MAX_ROWS
        values.map(&.as_s)
      end

      private def planned_owner(table : String, value : JSON::Any) : String?
        @changes["#{table}/#{value["id"].as_s}"]?.try(&.target_organisation_id) || owner(value)
      end

      private def block(code : String, table : String?, id : String?, message : String)
        @blockers << Blocker.new(code, table, id, message)
      end

      private def stage(table : String, value : JSON::Any, source : String?, target : String, claim : Bool)
        id = value["id"].as_s
        actual = owner(value)
        return if claim && actual == target
        if actual != source
          block("owner_mismatch", table, id, "resource does not have the reviewed source owner")
          return
        end
        if existing = @changes["#{table}/#{id}"]?
          block("conflicting_operations", table, id, "operations assign different owners") if existing.target_organisation_id != target
        else
          oversized! if @changes.size >= MAX_ROWS
          @changes["#{table}/#{id}"] = Change.new(table, id, actual, target)
        end
      end

      private def expand(operation : Operation)
        source = operation.source_organisation_id.try(&.to_s)
        target = operation.target_organisation_id.try(&.to_s)
        unless target && row("organisations", target)
          block("target_missing", "organisations", target, "target organisation does not exist")
          return
        end
        if source == target
          block("same_owner", "organisations", source, "source and target must differ")
          return
        end
        if source && !row("organisations", source)
          block("source_missing", "organisations", source, "source organisation does not exist")
          return
        end
        if source && staff_scope(source) != staff_scope(target)
          block("staff_conversion", "organisations", source, "staff privilege conversion requires separate provisioning")
          return
        end
        claim = operation.kind == "claim"
        if operation.kind != "merge_organisations" && (operation.resource_ids.empty? || operation.resource_ids.size > 500)
          block("resource_ids", operation.resource_type, nil, "provide between one and 500 resource IDs")
          return
        end
        unless claim || source
          block("source_required", nil, nil, "review the current source organisation")
          return
        end
        case operation.kind
        when "merge_organisations"
          OWNED.each { |table| observe(table, "r.organisation_id = $1::uuid", [source.not_nil!]).each { |value| stage(table, value, source, target, false) } }
          grants = observe("grants", "r.scope_type = 'organisation' AND r.scope_id IN ($1, $2)", [source.not_nil!, target])
          grants.group_by(&.["user_id"].as_s).each do |_, held|
            if held.size > 1
              block("grant_collision", "grants", held.first["id"].as_s, "resolve grant permissions and expiry explicitly before merging")
            end
          end
          grants.select { |grant| grant["scope_id"].as_s == source }.each do |grant|
            grant_id = grant["id"].as_s
            @grants[grant_id] = GrantChange.new(grant_id, grant["user_id"].as_s, source.not_nil!, target, grant["permissions"].as_i, field(grant, "expires_at"))
          end
          @retained << source.not_nil!
        when "move_domain"
          unless operation.resource_type == "authority"
            block("resource_type", nil, nil, "move_domain requires authority resources")
            return
          end
          operation.resource_ids.each do |id|
            if authority = row("authority", id)
              stage("authority", authority, source, target, false)
              authorities = observe("authority", "r.organisation_id = $1::uuid", [source.not_nil!])
              if authorities.size == 1
                OWNED.reject("authority").each { |table| observe(table, "r.organisation_id = $1::uuid", [source.not_nil!]).each { |value| stage(table, value, source, target, false) } }
              else
                block("domain_estate_ambiguous", "authority", id, "shared-domain estates require an organisation merge or prior separation of their references")
              end
            else
              block("resource_missing", "authority", id, "domain does not exist")
            end
          end
        when "claim", "move_zone_tree", "reassign"
          table = operation.resource_type
          unless table && OWNED.includes?(table) && table != "authority"
            block("resource_type", table, nil, "use a supported estate type; domains use move_domain")
            return
          end
          if claim && source
            block("claim_source", table, nil, "claim is only for resources with no owner")
            return
          end
          operation.resource_ids.each do |id|
            if table == "zone"
              expand_tree(id, source, target, claim)
            elsif value = row(table, id)
              stage(table, value, source, target, claim)
              expand_system(value, source, target, claim) if table == "sys"
            else
              block("resource_missing", table, id, "resource does not exist")
            end
          end
        else
          block("operation_kind", nil, nil, "unsupported reconciliation operation")
        end
      end

      private def staff_scope(id : String) : String
        organisation = row("organisations", id).not_nil!
        staff = organisation["partner_staff"]?.try(&.as_bool?) || false
        return "customer" unless staff
        partner_id = field(organisation, "partner_id")
        partner_id.try { |pid| row("partners", pid) }
        "staff:#{partner_id}"
      end

      private def expand_tree(root : String, source : String?, target : String, claim : Bool)
        tree = observe("zone", <<-SQL, [root])
          r.id IN (WITH RECURSIVE tree AS (
            SELECT id FROM zone WHERE id = $1
            UNION SELECT z.id FROM zone z JOIN tree t ON z.parent_id = t.id
          ) SELECT id FROM tree LIMIT #{MAX_ROWS + 1})
          SQL
        if tree.empty?
          block("resource_missing", "zone", root, "zone tree does not exist")
          return
        end
        tree.each { |zone| stage("zone", zone, source, target, claim) }
        zone_ids = tree.map(&.["id"].as_s)
        placeholder = zone_ids.map_with_index { |_, i| "$#{i + 1}" }.join(',')
        systems = observe("sys", "EXISTS (SELECT 1 FROM unnest(r.zones) z WHERE z IN (#{placeholder}))", zone_ids)
        systems.each do |system|
          stage("sys", system, source, target, claim)
          expand_system(system, source, target, claim)
        end
      end

      private def expand_system(system : JSON::Any, source : String?, target : String, claim : Bool)
        system_id = system["id"].as_s
        module_ids = ids(system, "modules")
        if module_ids.empty?
          observe("mod", "r.control_system_id = $1", [system_id]).each { |value| stage("mod", value, source, target, claim) }
        else
          placeholders = module_ids.map_with_index { |_, i| "$#{i + 2}" }.join(',')
          observe("mod", "r.control_system_id = $1 OR r.id IN (#{placeholders})", [system_id] + module_ids).each { |value| stage("mod", value, source, target, claim) }
        end
        observe("trigger", "r.control_system_id = $1", [system_id]).each { |value| stage("trigger", value, source, target, claim) }
      end

      private def compatible_reference(table : String, id : String?, expected : String, subject : Change)
        return unless id
        value = row(table, id)
        if value.nil? || planned_owner(table, value) != expected
          block("reference_owner", subject.resource_type, subject.resource_id, "#{table} reference is missing, unknown or outside the destination")
        end
      end

      private def validate_references
        # Observe referrers as well as outgoing references. Rebuilding this
        # under locks detects new rows added after a preview.
        @changes.values.each do |change|
          table, id, target = change.resource_type, change.resource_id, change.target_organisation_id
          value = @rows["#{table}/#{id}"]
          case table
          when "authority"
            root = value["config"]?.try(&.as_h?).try(&.["org_zone"]?).try(&.as_s?)
            compatible_reference("zone", root, target, change)
            users = observe("user", "r.authority_id = $1", [id])
            keys = observe("api_key", "r.authority_id = $1", [id])
            active = users.reject { |user| user["deleted"].as_bool? == true }
            @access[id] = AccessChange.new(id, change.source_organisation_id, target, users.size, keys.size,
              users.map(&.["id"].as_s).sort!.first(SAMPLE_SIZE), keys.map(&.["id"].as_s).sort!.first(SAMPLE_SIZE),
              active.count { |user| user["sys_admin"].as_bool? == true }, active.count { |user| user["support"].as_bool? == true },
              users.size <= SAMPLE_SIZE && keys.size <= SAMPLE_SIZE)
          when "zone"
            compatible_reference("zone", field(value, "parent_id"), target, change)
            observe("zone", "r.parent_id = $1", [id]).each { |child| compatible_reference("zone", child["id"].as_s, target, change) }
            observe("sys", "$1 = ANY(r.zones)", [id]).each { |sys| compatible_reference("sys", sys["id"].as_s, target, change) }
            observe("authority", "r.config->>'org_zone' = $1", [id]).each { |auth| compatible_reference("authority", auth["id"].as_s, target, change) }
            observe("group_zones", "r.zone_id = $1", [id]).each do |anchor|
              group = row("groups", anchor["group_id"].as_s)
              if authority = group.try { |item| field(item, "authority_id") }
                compatible_reference("authority", authority, target, change)
              else
                block("unknown_group_owner", "zone", id, "resolve the anchored group owner before moving this zone")
              end
            end
            observe("pending_mail", "$1 = ANY(r.zones)", [id]).each { |mail| compatible_reference("authority", field(mail, "authority_id"), target, change) }
            observe("asset", "$1 = ANY(r.zones) OR r.zone_id = $1", [id]).each do |asset|
              type = field(asset, "asset_type_id").try { |type_id| row("asset_type", type_id) }
              category = type.try { |item| field(item, "category_id") }.try { |category_id| row("asset_category", category_id) }
              authority = category.try { |item| field(item, "authority_id") }
              if authority
                compatible_reference("authority", authority, target, change)
              else
                block("unknown_asset_owner", "zone", id, "resolve asset ownership before moving this zone")
              end
            end
            observe("trig", "r.zone_id = $1", [id]).each { |instance| validate_instance(instance, target, change) }
          when "sys"
            ids(value, "zones").each { |zone_id| compatible_reference("zone", zone_id, target, change) }
            ids(value, "modules").each { |module_id| compatible_reference("mod", module_id, target, change) }
            observe("mod", "r.control_system_id = $1", [id]).each { |mod| compatible_reference("mod", mod["id"].as_s, target, change) }
            observe("trigger", "r.control_system_id = $1", [id]).each { |trigger| compatible_reference("trigger", trigger["id"].as_s, target, change) }
            observe("trig", "r.control_system_id = $1", [id]).each { |instance| validate_instance(instance, target, change) }
          when "mod"
            compatible_reference("sys", field(value, "control_system_id"), target, change)
            compatible_reference("edge", field(value, "edge_id"), target, change)
            observe("sys", "$1 = ANY(r.modules)", [id]).each { |sys| compatible_reference("sys", sys["id"].as_s, target, change) }
          when "trigger"
            compatible_reference("sys", field(value, "control_system_id"), target, change)
            observe("trig", "r.trigger_id = $1", [id]).each { |instance| validate_instance(instance, target, change) }
          when "edge"
            observe("mod", "r.edge_id = $1", [id]).each { |mod| compatible_reference("mod", mod["id"].as_s, target, change) }
            if user_id = field(value, "user_id")
              user = row("user", user_id)
              compatible_reference("authority", user.try { |item| field(item, "authority_id") }, target, change)
              block("missing_reference", table, id, "edge user does not exist") unless user
              key = field(value, "api_key_id").try { |key_id| row("api_key", key_id) }
              user_authority = user.try { |principal| field(principal, "authority_id") }
              if key && user_authority && field(key, "user_id") == user_id && field(key, "authority_id") == user_authority
                compatible_reference("authority", user_authority, target, change)
              else
                block("reference_owner", table, id, "edge credential is missing or belongs to another principal")
              end
            else
              block("reference_owner", table, id, "edge principal is missing")
            end
          end
        end
      end

      private def validate_instance(instance : JSON::Any, target : String, change : Change)
        %w[control_system_id trigger_id].each do |key|
          block("reference_owner", change.resource_type, change.resource_id, "trigger instance has a missing required reference") unless field(instance, key)
        end
        compatible_reference("sys", field(instance, "control_system_id"), target, change)
        compatible_reference("zone", field(instance, "zone_id"), target, change)
        if id = field(instance, "trigger_id")
          trigger = row("trigger", id)
          # Unowned, unscoped trigger definitions are intentional shared templates.
          unless trigger && owner(trigger).nil? && field(trigger, "control_system_id").nil?
            compatible_reference("trigger", id, target, change)
          end
        end
      end

      private def validate_names
        @changes.values.select { |change| NAMED.includes?(change.resource_type) }.each do |change|
          value = @rows["#{change.resource_type}/#{change.resource_id}"]
          next unless name = field(value, "name")
          observe(change.resource_type, "r.name = $1", [name]).each do |other|
            next if other["id"].as_s == change.resource_id
            if planned_owner(change.resource_type, other) == change.target_organisation_id
              block("name_collision", change.resource_type, change.resource_id, "destination already contains this name")
            end
          end
        end
      end

      private def validate_administrators
        owners = @changes.values.flat_map { |change| [change.source_organisation_id, change.target_organisation_id].compact }.uniq!.sort!
        owners.each do |id|
          authorities = observe("authority", "r.organisation_id = $1::uuid", [id])
          next if authorities.empty?
          placeholders = authorities.map_with_index { |_, i| "$#{i + 1}" }.join(',')
          admins = observe("user", "r.sys_admin AND NOT r.deleted AND r.authority_id IN (#{placeholders})", authorities.map(&.["id"].as_s))
          next if admins.empty?
          kept_domains = authorities.select { |auth| planned_owner("authority", auth) == id }
          next if kept_domains.empty?
          if admins.none? { |user| kept_domains.any? { |auth| auth["id"].as_s == field(user, "authority_id") } }
            block("last_administrator", "organisations", id, "move would remove the last active administrator")
          end
        end
      end
    end
  end
end
