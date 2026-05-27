require "./application"

module PlaceOS::Api
  class PendingMails < Application
    include Utils::Permissions
    include Utils::GroupPermissions

    base "/api/engine/v2/emails/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:destroy, :reject, :sent, :cleanup]

    ###############################################################################################

    # `cleanup` operates on a whole authority (no record id); `index` lists.
    @[AC::Route::Filter(:before_action, except: [:index, :cleanup])]
    def current_pending_mail(id : String)
      Log.context.set(pending_mail_id: id)
      # Primary key is a UUID — a non-UUID id is simply "not found".
      uuid = UUID.parse?(id)
      raise Error::NotFound.new("invalid pending mail id: #{id}") if uuid.nil?
      # Find will raise a 404 (not found) if there is an error
      @current_pending_mail = ::PlaceOS::Model::PendingMail.find!(uuid)
    end

    getter! current_pending_mail : ::PlaceOS::Model::PendingMail

    # Permissions
    ###############################################################################################

    # Non-support callers may only view mail belonging to their own authority.
    @[AC::Route::Filter(:before_action, only: [:show])]
    def check_show_access
      return if user_support?
      raise Error::Forbidden.new unless current_pending_mail.authority_id == current_user.authority_id
    end

    # Gate a mutating action (destroy/reject/sent) on the "support" subsystem.
    # `required` is the permission bit the verb needs (Delete/Update); Manage
    # is a superset. A non-support user is allowed when EITHER the legacy
    # org-zone scheme grants Manage, OR they have the required (or Manage)
    # support-subsystem reach on ANY of the mail's zones. Mail with no zones
    # is admin/support only.
    private def confirm_mutate(required : ::PlaceOS::Model::Permissions)
      return if user_support?

      mail = current_pending_mail
      authority = current_authority.as(::PlaceOS::Model::Authority)

      # Legacy zone-based access (org_zone + the mail's zones).
      if org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
        return if check_access(current_user.groups, [org_zone_id] + mail.zones).can_manage?
      end

      # "support" subsystem: OR'd across the mail's zones (the Array overload
      # of effective_permissions already does this).
      perms = ::PlaceOS::Model::Group.effective_permissions(
        authority.id.as(String), "support", current_user.id.as(String), mail.zones,
      )
      return if perms.manage? || perms.includes?(required)

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list queued/processed mail, filtered via Elasticsearch
    @[AC::Route::GET("/", converters: {zones: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "only mail whose zones are anchored to this group; non-support callers need Read on the group", example: "group-uuid")]
      group_id : UUID? = nil,
      @[AC::Param::Info(description: "only mail referencing any of these zones", example: "zone-1234,zone-5678")]
      zones : Array(String)? = nil,
      @[AC::Param::Info(description: "only mail queued by this service", example: "bookings")]
      source_service : String? = nil,
      @[AC::Param::Info(description: "only mail with this external reference / correlation id", example: "booking-1234")]
      source_reference : String? = nil,
      @[AC::Param::Info(description: "filter by authority (system admin / support only; regular users are scoped to their own authority)", example: "authority-1234")]
      authority_id : String? = nil,
      @[AC::Param::Info(description: "only mail triggered by this user", example: "user-1234")]
      user_id : String? = nil,
      @[AC::Param::Info(description: "include mail past its expiry (default false)", example: "true")]
      include_expired : Bool = false,
      @[AC::Param::Info(description: "include mail that has been rejected (default false)", example: "true")]
      include_rejected : Bool = false,
      @[AC::Param::Info(description: "only mail that is neither sent nor rejected (default false)", example: "true")]
      unsent_only : Bool = false,
      @[AC::Param::Info(description: "mail sent at or after this time (also matches rejected time when include_rejected=true)")]
      sent_after : Time? = nil,
      @[AC::Param::Info(description: "mail sent at or before this time (also matches rejected time when include_rejected=true)")]
      sent_before : Time? = nil,
      @[AC::Param::Info(description: "mail scheduled to send at or after this time")]
      send_at_after : Time? = nil,
    ) : Array(::PlaceOS::Model::PendingMail)
      elastic = ::PlaceOS::Model::PendingMail.elastic
      query = elastic.query(search_params)

      # Authority scoping: regular users are pinned to their own authority;
      # only support/admin may target another (or all) authorities.
      if requested = authority_id
        raise Error::Forbidden.new unless user_support?
        query.filter({"authority_id" => [requested]})
      elsif !user_support?
        query.filter({"authority_id" => [current_user.authority_id.as(String)]})
      end

      # Group-anchor filter: resolve the group's zones first so we can
      # short-circuit on an empty set (and never run unconstrained).
      if group = group_id
        unless user_support?
          perms = group_memberships(current_user)[group]? || ::PlaceOS::Model::Permissions::None
          raise Error::Forbidden.new unless perms.read?
        end
        group_zone_ids = ::PlaceOS::Model::GroupZone.where(group_id: group).to_a.map(&.zone_id)
        if group_zone_ids.empty?
          set_collection_headers(0, ::PlaceOS::Model::PendingMail.table_name)
          return [] of ::PlaceOS::Model::PendingMail
        end
        query.filter({"zones" => group_zone_ids})
      end

      if (filter_zones = zones) && !filter_zones.empty?
        query.must({"zones" => filter_zones})
      end

      query.filter({"source_service" => [source_service]}) if source_service
      query.filter({"source_reference" => [source_reference]}) if source_reference
      query.filter({"user_id" => [user_id]}) if user_id

      # Exclude rejected mail unless explicitly requested (nil ⇒ must_not exists).
      query.filter({"rejected_at" => [nil] of String?}) unless include_rejected

      # Neither sent nor rejected.
      query.filter({"sent_at" => [nil] of String?, "rejected_at" => [nil] of String?}) if unsent_only

      # Not expired: expiry missing OR in the future. Needs an OR group that
      # mixes a missing-field check with a range, so it goes in raw.
      unless include_expired
        query.raw_filter(JSON.parse({
          bool: {
            should: [
              {bool: {must_not: {exists: {field: "expiry"}}}},
              {range: {expiry: {gte: Time.utc.to_rfc3339}}},
            ],
            minimum_should_match: 1,
          },
        }.to_json))
      end

      # Sent window. When include_rejected is set, the window also matches the
      # rejected time (a mail is either sent or rejected) — an OR across two
      # range fields, hence raw.
      if sent_after || sent_before
        window = time_window(sent_after, sent_before)
        if include_rejected
          query.raw_filter(JSON.parse({
            bool: {
              should: [
                {range: {sent_at: window}},
                {range: {rejected_at: window}},
              ],
              minimum_should_match: 1,
            },
          }.to_json))
        else
          query.raw_filter(JSON.parse({range: {sent_at: window}}.to_json))
        end
      end

      if send_at = send_at_after
        query.raw_filter(JSON.parse({range: {send_at: {gte: send_at.to_rfc3339}}}.to_json))
      end

      query.sort({"created_at" => {order: :desc}})
      paginate_results(elastic, query)
    end

    # RFC3339 range bounds for ES. These Time fields (send_at/expiry/sent_at/
    # rejected_at) are mapped as ES `date` and serialized as ISO8601 strings —
    # a bare integer in a range would be read as epoch-millis, so use strings.
    private def time_window(after : Time?, before : Time?) : Hash(String, String)
      window = {} of String => String
      window["gte"] = after.to_rfc3339 if after
      window["lte"] = before.to_rfc3339 if before
      window
    end

    # show the selected mail
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::PendingMail
      current_pending_mail
    end

    # remove a queued/processed mail
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      confirm_mutate(::PlaceOS::Model::Permissions::Delete)
      current_pending_mail.destroy
    end

    # mark a mail as rejected (it will not be sent)
    @[AC::Route::POST("/:id/reject")]
    def reject(
      @[AC::Param::Info(description: "human readable reason the mail was rejected", example: "recipient opted out")]
      rejected_reason : String? = nil,
    ) : ::PlaceOS::Model::PendingMail
      confirm_mutate(::PlaceOS::Model::Permissions::Update)
      mail = current_pending_mail
      mail.rejected_at = Time.utc
      mail.rejected_reason = rejected_reason if rejected_reason
      raise Error::ModelValidation.new(mail.errors) unless mail.save
      mail
    end

    # mark a mail as sent
    @[AC::Route::POST("/:id/sent")]
    def sent(
      @[AC::Param::Info(description: "the worker / service that sent the mail", example: "mailer")]
      sent_by : String? = nil,
    ) : ::PlaceOS::Model::PendingMail
      confirm_mutate(::PlaceOS::Model::Permissions::Update)
      mail = current_pending_mail
      mail.sent_at = Time.utc
      mail.sent_by = sent_by if sent_by
      raise Error::ModelValidation.new(mail.errors) unless mail.save
      mail
    end

    # delete all sent, rejected and expired mail for an authority (admin/support)
    @[AC::Route::DELETE("/cleanup", status_code: HTTP::Status::ACCEPTED)]
    def cleanup(
      @[AC::Param::Info(description: "authority to clean up (defaults to the caller's authority)", example: "authority-1234")]
      authority_id : String? = nil,
    ) : Nil
      check_support
      target = authority_id || current_user.authority_id.as(String)
      ::PlaceOS::Model::PendingMail
        .where(authority_id: target)
        .where("(rejected_at IS NOT NULL OR sent_at IS NOT NULL OR (expiry IS NOT NULL AND expiry < ?))", Time.utc)
        .delete_all
    end
  end
end
