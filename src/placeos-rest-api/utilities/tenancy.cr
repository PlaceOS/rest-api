require "uuid"
require "placeos-models/authority"
require "placeos-models/organisation"
require "placeos-models/partner"
require "placeos-models/grant"

require "../../constants"

module PlaceOS::Api
  # Resolves, once per request, which organisations the caller may reach, and
  # exposes the scope filter and reach checks the controllers apply.
  #
  # Reach is structural first and granted second:
  # - cluster: an admin or support user whose domain's organisation belongs to
  #   the management partner. Sees every organisation, as before PPT-526.
  # - partner: an admin or support user on a partner's staff organisation
  #   (`organisations.partner_staff`). Sees every organisation under that partner.
  # - organisation: everyone else sees their own organisation only.
  # Live grants widen the organisation set without changing the level.
  #
  # Rows with no organisation (unowned) are visible to cluster reach only.
  # A caller whose domain has no organisation reaches nothing.
  #
  # `Tenancy.enforce?` (from `PLACE_TENANCY_ENFORCE`) switches between refusing
  # and logging what would have been refused; the resolver runs either way.
  module Utils::Tenancy
    Log = ::Log.for("tenancy")

    class_property? enforce : Bool = PLACE_TENANCY_ENFORCE

    enum Reach
      Cluster
      Partner
      Organisation
    end

    # Shape `Error::ModelValidation` reads failures from
    record Failure, field : Symbol, message : String

    # The resolved reach of the current request. `organisation_ids` is nil for
    # cluster reach (no filter) and otherwise the exact set, possibly empty.
    record Scope,
      reach : Reach,
      organisation_ids : Set(UUID)?,
      organisation : ::PlaceOS::Model::Organisation?,
      partner : ::PlaceOS::Model::Partner? do
      def cluster? : Bool
        reach.cluster?
      end

      def includes?(organisation_id : UUID?) : Bool
        return true if cluster?
        return false if organisation_id.nil?
        organisation_ids.as(Set(UUID)).includes?(organisation_id)
      end

      def organisation_id : UUID?
        organisation.try(&.id)
      end
    end

    getter current_organisation : ::PlaceOS::Model::Organisation? { current_authority.try(&.organisation) }
    getter current_partner : ::PlaceOS::Model::Partner? { current_organisation.try(&.partner_id).try { |id| ::PlaceOS::Model::Partner.find?(id) } }

    # The caller's reach as it will be once enforcement is on. Controllers
    # never read this directly for gating; see `tenancy`.
    getter resolved_tenancy : Scope { resolve_tenancy }

    # The scope controllers apply. With enforcement off this is always cluster
    # reach, so behaviour matches the release before PPT-526.
    getter tenancy : Scope do
      if Utils::Tenancy.enforce?
        resolved_tenancy
      else
        Scope.new(Reach::Cluster, nil, current_organisation, current_partner)
      end
    end

    protected def resolve_tenancy : Scope
      organisation = current_organisation
      partner = current_partner
      privileged = user_support?

      if organisation.nil?
        Log.warn { {message: "domain has no organisation, caller reaches nothing", authority: current_authority.try(&.id), user_id: user_token.id} }
        return Scope.new(Reach::Organisation, Set(UUID).new, nil, nil)
      end

      organisation_id = organisation.id.as(UUID)

      if privileged && partner && partner.management
        return Scope.new(Reach::Cluster, nil, organisation, partner)
      end

      reach, ids = if privileged && partner && organisation.partner_staff
                     {Reach::Partner, organisation.partner_organisations.to_a.compact_map(&.id).to_set}
                   else
                     {Reach::Organisation, Set{organisation_id}}
                   end

      ids.concat(granted_organisation_ids)
      Scope.new(reach, ids, organisation, partner)
    end

    # Organisations the caller reaches through live grants that carry Read.
    protected def granted_organisation_ids : Set(UUID)
      ids = Set(UUID).new
      return ids if user_token.guest_scope?
      user_id = user_token.id

      ::PlaceOS::Model::Grant.for_user(user_id).each do |grant|
        next unless grant.permission_flags.read? || grant.permission_flags.manage?
        scope_id = grant.scope_id
        case grant.scope_type
        when ::PlaceOS::Model::Grant::SCOPE_ORGANISATION
          UUID.parse?(scope_id).try { |id| ids << id }
        when ::PlaceOS::Model::Grant::SCOPE_PARTNER
          if partner_id = UUID.parse?(scope_id)
            ::PlaceOS::Model::Organisation.where(partner_id: partner_id).each { |org| org.id.try { |id| ids << id } }
          end
        when ::PlaceOS::Model::Grant::SCOPE_AUTHORITY
          ::PlaceOS::Model::Authority.find?(scope_id).try(&.organisation_id).try { |id| ids << id }
        end
      end
      ids
    end

    # ------------------------------------------------------------------
    # Gates
    # ------------------------------------------------------------------

    # Cluster-only routes (repositories, drivers, brokers, cluster, build jobs).
    def check_cluster_admin
      raise Error::Forbidden.new unless user_admin?
      return if tenancy.cluster?
      log_would_refuse("cluster admin required")
      raise Error::Forbidden.new if Utils::Tenancy.enforce?
    end

    # Raises 404 when `organisation_id` is outside the caller's reach, so a
    # foreign id is indistinguishable from an unknown one. Unowned rows are in
    # reach for cluster callers only.
    def ensure_reach!(organisation_id : UUID?, resource : String = "resource") : Nil
      return if tenancy.includes?(organisation_id)
      log_would_refuse("#{resource} outside reach", organisation_id)
      raise Error::NotFound.new("#{resource} not found") if Utils::Tenancy.enforce?
    end

    def ensure_reach!(row : ::PlaceOS::Model::Authority | ::PlaceOS::Model::Zone | ::PlaceOS::Model::ControlSystem | ::PlaceOS::Model::Module | ::PlaceOS::Model::Trigger | ::PlaceOS::Model::Edge | ::PlaceOS::Model::Broker) : Nil
      ensure_reach!(row.organisation_id, row.class.table_name)
    end

    # Reach for a row owned through its domain (users, api keys, auth sources,
    # OAuth applications).
    def ensure_authority_reach!(authority_id : String?, resource : String = "resource") : Nil
      return if tenancy.cluster?
      organisation_id = authority_id.try { |id| ::PlaceOS::Model::Authority.find?(id).try(&.organisation_id) }
      ensure_reach!(organisation_id, resource)
    end

    # True when the caller may act on `organisation_id`; the quiet form of
    # `ensure_reach!` for building filtered lists.
    def in_reach?(organisation_id : UUID?) : Bool
      tenancy.includes?(organisation_id)
    end

    # ------------------------------------------------------------------
    # Query scoping
    # ------------------------------------------------------------------

    # Appends the reach filter to a relation on a table with an
    # `organisation_id` column. No-op for cluster reach.
    def scope_organisations(query, column : String = "organisation_id")
      ids = tenancy.organisation_ids
      return query if ids.nil?
      if ids.empty?
        query.where("1 = ?", 0)
      else
        list = ids.to_a.map(&.to_s)
        query.where("#{column} = ANY(ARRAY[#{list.join(", ") { "?" }}]::uuid[])", list)
      end
    end

    # As above for tables owned through their domain (`authority_id`).
    def scope_authorities(query, column : String = "authority_id")
      ids = tenancy.organisation_ids
      return query if ids.nil?
      if ids.empty?
        query.where("1 = ?", 0)
      else
        list = ids.to_a.map(&.to_s)
        query.where("#{column} IN (SELECT id FROM authority WHERE organisation_id = ANY(ARRAY[#{list.join(", ") { "?" }}]::uuid[]))", list)
      end
    end

    # Domain ids in reach, for routes that take an `authority_id` parameter.
    def reachable_authority_ids : Array(String)?
      ids = tenancy.organisation_ids
      return if ids.nil?
      return [] of String if ids.empty?
      list = ids.to_a.map(&.to_s)
      ::PlaceOS::Model::Authority
        .where("organisation_id = ANY(ARRAY[#{list.join(", ") { "?" }}]::uuid[])", list)
        .to_a.compact_map(&.id)
    end

    # The single organisation implied by a set of zone ids: every zone must be
    # in reach and owned by the same organisation. Falls back to the caller's
    # own organisation when the zones are unowned or there are none.
    def organisation_for_zones(zone_ids : Array(String)) : UUID?
      owners = Set(UUID).new
      zone_ids.uniq.each do |zone_id|
        zone = ::PlaceOS::Model::Zone.find!(zone_id)
        ensure_reach!(zone)
        zone.organisation_id.try { |id| owners << id }
      end
      raise Error::ModelValidation.new([Failure.new(:zones, "zones belong to more than one organisation")], "zones belong to more than one organisation") if owners.size > 1
      owners.first? || tenancy.organisation_id
    end

    # Reach check for a settings/metadata parent id (zone-, sys-, mod-, user-
    # or driver- prefixed). Drivers are global, so a driver parent is always
    # in reach for reads.
    def ensure_parent_reach!(parent_id : String) : Nil
      case parent_id
      when .starts_with?("zone-")   then ensure_reach!(::PlaceOS::Model::Zone.find!(parent_id))
      when .starts_with?("sys-")    then ensure_reach!(::PlaceOS::Model::ControlSystem.find!(parent_id))
      when .starts_with?("mod-")    then ensure_reach!(::PlaceOS::Model::Module.find!(parent_id))
      when .starts_with?("user-")   then ensure_authority_reach!(::PlaceOS::Model::User.find!(parent_id).authority_id, "user")
      when .starts_with?("driver-") then nil
      else                               ensure_reach!(nil, "parent")
      end
    end

    # Quiet form of `ensure_parent_reach!` for filtering id lists.
    def parent_in_reach?(parent_id : String) : Bool
      return true if tenancy.cluster? || !Utils::Tenancy.enforce?
      ensure_parent_reach!(parent_id)
      true
    rescue Error::NotFound | PgORM::Error::RecordNotFound
      false
    end

    # The organisation a newly created estate row belongs to: the caller's own,
    # or, for cluster callers, an explicit choice.
    def organisation_for_new_row(requested : UUID? = nil) : UUID?
      if requested
        raise Error::Forbidden.new("organisation outside reach") unless in_reach?(requested)
        return requested
      end
      tenancy.organisation_id
    end

    protected def log_would_refuse(reason : String, organisation_id : UUID? = nil)
      scope = resolved_tenancy
      Log.warn do
        {
          message:    Utils::Tenancy.enforce? ? "tenancy refused" : "tenancy would refuse",
          reason:     reason,
          reach:      scope.reach.to_s,
          caller_org: scope.organisation_id.try(&.to_s),
          target_org: organisation_id.try(&.to_s),
          user_id:    user_token.id,
          path:       request.path,
        }
      end
    end
  end
end
