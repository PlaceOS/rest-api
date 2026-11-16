require "uuid"
require "placeos-models/authority"
require "placeos-models/organisation"
require "placeos-models/partner"
require "placeos-models/grant"
require "../../constants"
require "./tenancy_policy"

module PlaceOS::Api
  # Identity reach and the selected resource organisation are separate. All
  # resource gates and queries use the selection, while discovery uses reach.
  module Utils::Tenancy
    Log = ::Log.for("tenancy")
    class_property? enforce : Bool = PLACE_TENANCY_ENFORCE

    enum Reach
      Cluster
      Partner
      Organisation
    end

    record Failure, field : Symbol, message : String
    record Scope,
      reach : Reach,
      organisation_ids : Set(UUID)?,
      organisation : ::PlaceOS::Model::Organisation?,
      partner : ::PlaceOS::Model::Partner? do
      def cluster? : Bool
        reach.cluster? && organisation_ids.nil?
      end

      def includes?(organisation_id : UUID?) : Bool
        return true if cluster?
        !organisation_id.nil? && organisation_ids.as(Set(UUID)).includes?(organisation_id)
      end

      def organisation_id : UUID?
        organisation.try(&.id)
      end
    end

    getter current_organisation : ::PlaceOS::Model::Organisation? { current_authority.try(&.organisation) }
    getter current_partner : ::PlaceOS::Model::Partner? { current_organisation.try(&.partner_id).try { |id| ::PlaceOS::Model::Partner.find?(id) } }
    getter resolved_tenancy : Scope { Policy.new(user_token, current_authority.not_nil!.id.as(String), api_key_id: api_key.try(&.id)).scope }
    getter accessible_tenancy : Scope { Utils::Tenancy.enforce? ? resolved_tenancy : Scope.new(Reach::Cluster, nil, current_organisation, current_partner) }

    getter selected_organisation_id : UUID? do
      requested = query_params["organisation_id"]?
      if requested
        unless query_params.fetch_all("organisation_id").size == 1 && (id = UUID.parse?(requested))
          raise Error::OrganisationSelection.new("organisation_id must be one UUID", "invalid_organisation")
        end
        organisation = ::PlaceOS::Model::Organisation.find?(id)
        raise Error::NotFound.new("organisation not found") unless organisation && accessible_tenancy.includes?(id)
        id
      elsif Utils::Tenancy.enforce? && !resolved_tenancy.reach.organisation?
        raise Error::OrganisationSelection.new("select an organisation using organisation_id", "organisation_required")
      else
        current_organisation.try(&.id)
      end
    end

    getter tenancy_policy : Policy { Policy.new(user_token, current_authority.not_nil!.id.as(String), selected_organisation_id, api_key.try(&.id)) }

    getter tenancy : Scope do
      if Utils::Tenancy.enforce?
        id = selected_organisation_id
        organisation = id.try { |oid| ::PlaceOS::Model::Organisation.find?(oid) }
        Scope.new(Reach::Organisation, id ? Set{id} : Set(UUID).new, organisation, current_partner)
      else
        accessible_tenancy
      end
    end

    # The inherited parameter is also published to OpenAPI/MCP, whose tool
    # invoker forwards declared parameters into its synthetic HTTP requests.
    def prepare_organisation_selection(organisation_id : UUID? = nil, authority_id : String? = nil)
      return unless Utils::Tenancy.enforce? && @user_token
      if organisation_id || !organisation_selection_exempt?
        selected_organisation_id
      end
    end

    # Public callbacks remain domain-bound. Platform catalogs, administration
    # and identity endpoints work before the customer selector is populated.
    def organisation_selection_exempt? : Bool
      return true unless @user_token
      case self.class.name
      when "PlaceOS::Api::Organisations", "PlaceOS::Api::Partners", "PlaceOS::Api::Grants",
           "PlaceOS::Api::Settings", "PlaceOS::Api::Brokers", "PlaceOS::Api::Drivers", "PlaceOS::Api::Repositories",
           "PlaceOS::Api::Cluster", "PlaceOS::Api::Schema", "PlaceOS::Api::BuildMonitor",
           "PlaceOS::Api::Flux", "PlaceOS::Api::History", "PlaceOS::Api::MQTT", "PlaceOS::Api::PushNotifications",
           "PlaceOS::Api::TenantConsent", "PlaceOS::Api::UrlProxy", "PlaceOS::Api::PublicEvents",
           "PlaceOS::Api::Webhook", "PlaceOS::Api::WebRTC"
        true
      when "PlaceOS::Api::Root"
        action_name != :signal
      when "PlaceOS::Api::Users"
        action_name.in?({:current, :resource_token, :groups})
      when "PlaceOS::Api::Metadata"
        parent_id = route_params["id"]?
        !parent_id.nil? && (parent_id == user_token.id || parent_id.starts_with?("driver-"))
      when "PlaceOS::Api::ApiKeys"
        action_name == :inspect_key
      when "PlaceOS::Api::Triggers"
        action_name.in?({:create, :update, :destroy})
      when "PlaceOS::Api::Edges"
        action_name.in?({:edges_health, :edges_errors, :edges_connections, :edges_module_failures, :edges_statistics, :edges_error_stream, :edges_module_stream, :cleanup_errors, :monitoring_summary})
      else
        false
      end
    end

    def tenancy_permission : ::PlaceOS::Model::Permissions
      case action_name
      when :logs
        ::PlaceOS::Model::Permissions::Read | ::PlaceOS::Model::Permissions::Operate
      when :execute, :start, :stop, :load, :ping, :signal
        ::PlaceOS::Model::Permissions::Operate
      when :settings, :edit, :update_media, :reorder, :schedule_media, :update_schedule, :rename_tag, :remove_tag, :cancel, :claim, :resolve
        ::PlaceOS::Model::Permissions::Update
      when :approve, :approve_media, :reject
        ::PlaceOS::Model::Permissions::Approve
      when :user_resource_token, :delete_resource_token
        ::PlaceOS::Model::Permissions::Manage
      when :share
        ::PlaceOS::Model::Permissions::Share
      else
        case request.method
        when "POST"         then ::PlaceOS::Model::Permissions::Create
        when "PUT", "PATCH" then ::PlaceOS::Model::Permissions::Update
        when "DELETE"       then ::PlaceOS::Model::Permissions::Delete
        else                     ::PlaceOS::Model::Permissions::Read
        end
      end
    end

    def check_cluster_admin
      raise Error::Forbidden.new unless user_admin?
      return if accessible_tenancy.cluster?
      log_would_refuse("cluster admin required")
      raise Error::Forbidden.new if Utils::Tenancy.enforce?
    end

    def ensure_discoverable_organisation!(id : UUID?)
      raise Error::NotFound.new("organisation not found") unless resolved_tenancy.includes?(id)
    end

    def ensure_reach!(organisation_id : UUID?, resource : String = "resource", required : ::PlaceOS::Model::Permissions = tenancy_permission) : Nil
      return unless Utils::Tenancy.enforce?
      raise Error::NotFound.new("#{resource} not found") unless tenancy.includes?(organisation_id)
      ensure_tenancy_permission!(organisation_id, required, resource)
    end

    def ensure_reach!(row : ::PlaceOS::Model::Authority | ::PlaceOS::Model::Zone | ::PlaceOS::Model::ControlSystem | ::PlaceOS::Model::Module | ::PlaceOS::Model::Trigger | ::PlaceOS::Model::Edge | ::PlaceOS::Model::Broker, required : ::PlaceOS::Model::Permissions = tenancy_permission) : Nil
      if row.is_a?(::PlaceOS::Model::Authority)
        ensure_authority_reach!(row.id, row.class.table_name, required)
      else
        ensure_reach!(row.organisation_id, row.class.table_name, required)
      end
    end

    def ensure_tenancy_permission!(organisation_id : UUID?, required : ::PlaceOS::Model::Permissions, resource : String = "resource", authority_id : String? = nil)
      return if tenancy_policy.permits?(organisation_id, required, authority_id)
      if required == ::PlaceOS::Model::Permissions::Read || !tenancy_policy.permits?(organisation_id, ::PlaceOS::Model::Permissions::Read, authority_id)
        raise Error::NotFound.new("#{resource} not found")
      end
      raise Error::Forbidden.new("missing #{required} permission")
    end

    def ensure_authority_reach!(authority_id : String?, resource : String = "resource", required : ::PlaceOS::Model::Permissions = tenancy_permission) : Nil
      return unless Utils::Tenancy.enforce?
      authority = authority_id.try { |id| ::PlaceOS::Model::Authority.find?(id) }
      raise Error::NotFound.new("#{resource} not found") unless authority && tenancy.includes?(authority.organisation_id)
      ensure_tenancy_permission!(authority.organisation_id, required, resource, authority.id)
    end

    def may_manage_authority?(authority_id : String?) : Bool
      return true unless Utils::Tenancy.enforce?
      authority = authority_id.try { |id| ::PlaceOS::Model::Authority.find?(id) }
      return false unless authority
      organisation = authority.organisation
      # Staff credentials can inherit partner or cluster reach. A narrow
      # grant must never manufacture an identity with that wider reach.
      return false if organisation.try(&.partner_staff) && !tenancy_policy.structural?(authority.organisation_id)
      tenancy_policy.permits?(authority.organisation_id, ::PlaceOS::Model::Permissions::Manage, authority.id)
    end

    def ensure_credential_management!(authority_id : String?)
      return unless Utils::Tenancy.enforce?
      ensure_authority_reach!(authority_id, "credentials", required: ::PlaceOS::Model::Permissions::Manage)
      raise Error::Forbidden.new("staff credential management requires structural access") unless may_manage_authority?(authority_id)
    end

    def in_reach?(organisation_id : UUID?, required : ::PlaceOS::Model::Permissions = tenancy_permission) : Bool
      return true unless Utils::Tenancy.enforce?
      tenancy.includes?(organisation_id) && tenancy_policy.permits?(organisation_id, required)
    end

    def permitted_organisation_ids(required : ::PlaceOS::Model::Permissions = tenancy_permission) : Set(UUID)?
      return unless Utils::Tenancy.enforce?
      id = selected_organisation_id
      id && tenancy_policy.permits?(id, required) ? Set{id} : Set(UUID).new
    end

    def scope_organisations(query, column : String = "organisation_id", required : ::PlaceOS::Model::Permissions = tenancy_permission)
      return query unless Utils::Tenancy.enforce?
      id = selected_organisation_id
      return query.where("1 = ?", 0) unless id && tenancy_policy.permits?(id, required)
      query.where("#{column} = ?::uuid", id.to_s)
    end

    def narrow_organisation(query, organisation_id : UUID?, column : String = "organisation_id")
      return query if organisation_id.nil?
      if Utils::Tenancy.enforce?
        raise Error::NotFound.new("organisation not found") unless selected_organisation_id == organisation_id
      end
      query.where("#{column} = ?::uuid", organisation_id.to_s)
    end

    def narrow_authorities(query, organisation_id : UUID?, column : String = "authority_id")
      return query if organisation_id.nil?
      if Utils::Tenancy.enforce?
        raise Error::NotFound.new("organisation not found") unless selected_organisation_id == organisation_id
      end
      query.where("#{column} IN (SELECT id FROM authority WHERE organisation_id = ?::uuid)", organisation_id.to_s)
    end

    def scope_authorities(query, column : String = "authority_id", required : ::PlaceOS::Model::Permissions = tenancy_permission)
      ids = reachable_authority_ids(required)
      return query if ids.nil?
      ids.empty? ? query.where("1 = ?", 0) : query.where("#{column} IN (#{ids.join(", ") { "?" }})", ids)
    end

    def reachable_authority_ids(required : ::PlaceOS::Model::Permissions = tenancy_permission) : Array(String)?
      return unless Utils::Tenancy.enforce?
      id = selected_organisation_id
      return [] of String unless id
      ::PlaceOS::Model::Authority.where(organisation_id: id).to_a.compact_map do |authority|
        authority.id if tenancy_policy.permits?(id, required, authority.id)
      end
    end

    def organisation_for_zones(zone_ids : Array(String)) : UUID?
      owners = Set(UUID).new
      zone_ids.uniq.each do |zone_id|
        zone = ::PlaceOS::Model::Zone.find!(zone_id)
        ensure_reach!(zone)
        zone.organisation_id.try { |id| owners << id }
      end
      if Utils::Tenancy.enforce? && owners.size > 1
        raise Error::ModelValidation.new([Failure.new(:zones, "zones belong to more than one organisation")])
      end
      owners.first? || organisation_for_new_row
    end

    def ensure_parent_reach!(parent_id : String, required : ::PlaceOS::Model::Permissions = tenancy_permission) : Nil
      case parent_id
      when .starts_with?("zone-")   then ensure_reach!(::PlaceOS::Model::Zone.find!(parent_id), required: required)
      when .starts_with?("sys-")    then ensure_reach!(::PlaceOS::Model::ControlSystem.find!(parent_id), required: required)
      when .starts_with?("mod-")    then ensure_reach!(::PlaceOS::Model::Module.find!(parent_id), required: required)
      when .starts_with?("user-")   then ensure_authority_reach!(::PlaceOS::Model::User.find!(parent_id).authority_id, "user", required: required)
      when .starts_with?("driver-") then check_cluster_admin unless request.method.in?({"GET", "HEAD"})
      else                               ensure_reach!(nil, "parent")
      end
    end

    def parent_in_reach?(parent_id : String) : Bool
      return true unless Utils::Tenancy.enforce?
      ensure_parent_reach!(parent_id)
      true
    rescue Error::NotFound | PgORM::Error::RecordNotFound
      false
    end

    def organisation_for_new_row(requested : UUID? = nil) : UUID?
      if Utils::Tenancy.enforce?
        id = selected_organisation_id
        raise Error::NotFound.new("organisation not found") if requested && requested != id
        ensure_reach!(id)
        id
      else
        requested || current_organisation.try(&.id)
      end
    end

    def settings_reader(parent_id : String) : ::PlaceOS::Model::User | ::PlaceOS::Model::UserJWT
      return current_user unless Utils::Tenancy.enforce?
      may_decrypt = if parent_id.starts_with?("driver-")
                      accessible_tenancy.cluster?
                    elsif parent_id.starts_with?("user-")
                      may_manage_authority?(::PlaceOS::Model::User.find!(parent_id).authority_id)
                    else
                      tenancy_policy.permits?(selected_organisation_id, ::PlaceOS::Model::Permissions::Manage)
                    end
      return current_user if may_decrypt
      token = user_token
      ::PlaceOS::Model::UserJWT.new(
        iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, scope: token.scope,
        user: ::PlaceOS::Model::UserJWT::Metadata.new(name: token.user.name, email: token.user.email, roles: token.user.roles),
      )
    end

    def collated_settings_for(model : ::PlaceOS::Model::ControlSystem | ::PlaceOS::Model::Module)
      hierarchy = model.settings_hierarchy.reverse!
      hierarchy.each do |setting|
        parent_id = setting.parent_id.as(String)
        ensure_parent_reach!(parent_id, required: ::PlaceOS::Model::Permissions::Read)
        setting.decrypt_for!(settings_reader(parent_id))
      end
      hierarchy
    end

    # Capture destinations and enforcement before a background publication.
    def publish_metadata_change(parent_id : String, action : Symbol, payload, authorities : Array(String)? = nil)
      scoped = Utils::Tenancy.enforce? && !parent_id.starts_with?("driver-")
      targets = authorities || if !scoped
        [current_authority.not_nil!.id.as(String)]
      elsif parent_id.starts_with?("user-")
        [::PlaceOS::Model::User.find!(parent_id).authority_id.as(String)]
      else
        reachable_authority_ids || [] of String
      end
      spawn do
        targets.each { |id| Api::Metadata.signal_metadata(id, action, payload, scoped: scoped) }
      end
    end

    def socket_tenancy_authorizer : Proc(String, ::PlaceOS::Model::Permissions, Bool)
      policy = tenancy_policy
      ->(id : String, permission : ::PlaceOS::Model::Permissions) { policy.system_access?(id, permission) }
    end

    def socket_tenancy_security : Proc(String, Driver::Proxy::RemoteDriver::Clearance)
      policy = tenancy_policy
      ->(id : String) { policy.system_security(id) }
    end

    protected def log_would_refuse(reason : String, organisation_id : UUID? = nil)
      Log.warn { {message: "tenancy refused", reason: reason, caller_org: current_organisation.try(&.id).try(&.to_s), target_org: organisation_id.try(&.to_s), user_id: user_token.id, path: request.path} }
    end
  end
end
