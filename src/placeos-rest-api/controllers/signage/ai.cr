require "placeos-models/metadata"
require "placeos-models/playlist/item"
require "placeos-models/signage_ai_job"
require "placeos-models/signage_ai_provider"
require "placeos-models/storage"
require "placeos-models/upload"

require "../application"

module PlaceOS::Api
  # Generate and edit signage artwork.
  #
  # A request validates, reserves a slot per vendor call, writes a job row and
  # hands off to a fiber, answering 202 immediately. The client then long polls
  # `jobs/:id`, which holds the connection until something changes or the wait
  # runs out, so a finished candidate reaches the browser within about half a
  # second of landing without a socket.
  class SignageAI < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/signage/ai"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:capabilities, :show_job, :index_jobs, :usage]
    before_action :can_write, only: [:generate, :edit, :cancel, :claim]

    ###############################################################################################

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

    @[AC::Route::Filter(:before_action, only: [:show_job, :cancel, :claim])]
    def find_current_job(id : UUID)
      Log.context.set(signage_ai_job: id.to_s)
      job = ::PlaceOS::Model::SignageAIJob.find!(id)
      raise Error::NotFound.new("no such job") unless job.authority_id == authority.id
      @current_job = job
    end

    getter! current_job : ::PlaceOS::Model::SignageAIJob

    # Requests
    ###############################################################################################

    struct GenerateParams
      include JSON::Serializable

      getter prompt : String = ""
      getter aspect_ratio : String = "16:9"
      getter quality : String = "standard"
      getter candidates : Int32 = 2
      getter references : Array(String) = [] of String
      getter include_logo : Bool = true
      getter add_text_with_layer : Bool = true
      getter words : String? = nil
      getter provider_id : UUID? = nil
      getter model : String? = nil
      getter group_id : UUID? = nil
      getter idempotency_key : String? = nil
    end

    struct EditParams
      include JSON::Serializable

      getter prompt : String = ""
      getter aspect_ratio : String = "16:9"
      getter quality : String = "standard"
      getter candidates : Int32 = 1
      getter references : Array(String) = [] of String
      getter include_logo : Bool = true
      getter add_text_with_layer : Bool = true
      getter words : String? = nil
      getter provider_id : UUID? = nil
      getter model : String? = nil
      getter group_id : UUID? = nil
      getter idempotency_key : String? = nil

      getter source_upload_id : String = ""
      getter source_item_id : String? = nil
      getter parent_job_id : UUID? = nil
    end

    struct ClaimParams
      include JSON::Serializable

      getter upload_id : String = ""
      getter item_id : String = ""
    end

    # Responses
    ###############################################################################################

    struct Capabilities
      include JSON::Serializable

      getter enabled : Bool
      getter reason : String?
      getter providers : Array(ImageGen::ProviderCapabilities)
      getter default_provider_id : String?
      getter aspect_ratios : Array(String)
      getter qualities : Array(String)
      getter max_candidates : Int32
      getter logo_layer : Bool
      getter quota : NamedTuple(user_remaining_today: Int32?, domain_remaining_month: Int32?)

      def initialize(@enabled, @providers, @default_provider_id, @quota,
                     @logo_layer = false, @reason = nil,
                     @aspect_ratios = ImageGen::ASPECTS,
                     @qualities = ImageGen::QUALITIES,
                     @max_candidates = ImageGen::MAX_CANDIDATES)
      end
    end

    struct JobResponse
      include JSON::Serializable

      getter id : String
      getter state : String
      getter kind : String
      getter provider : String?
      getter model : String?
      getter candidates : Int32
      getter images_produced : Int32
      getter parent_job_id : String?
      getter version : Int32
      getter prompt : String?
      getter images : Array(JSON::Any)
      getter error_kind : String?
      getter error_message : String?
      getter cost_units : Float64?
      getter latency_ms : Int64?
      getter created_at : Int64?
      getter finished_at : Int64?

      def initialize(job : ::PlaceOS::Model::SignageAIJob)
        @id = job.id.to_s
        @state = job.state.to_s
        @kind = job.kind.to_s
        @provider = job.provider_type
        @model = job.model
        @candidates = job.candidates
        @images_produced = job.images_produced
        @parent_job_id = job.parent_job_id.try(&.to_s)
        @version = job.version
        @prompt = job.prompt
        @images = job.images
        @error_kind = job.error_kind
        @error_message = job.error_message
        @cost_units = job.cost_units
        @latency_ms = job.latency_ms
        @created_at = job.created_at.try(&.to_unix)
        @finished_at = job.finished_at.try(&.to_unix)
      end
    end

    # Routes
    ###############################################################################################

    # what this domain can do, and what the caller has left of their quota
    @[AC::Route::GET("/capabilities")]
    def capabilities : Capabilities
      return disabled("the feature is switched off") if SIGNAGE_AI_DISABLED

      rows = ::PlaceOS::Model::SignageAIProvider.available_for(authority.id)
      return disabled("no AI provider is configured for this domain") if rows.empty?

      begin
        ::PlaceOS::Model::Storage.storage_or_default(authority.id)
      rescue
        return disabled("no upload storage is configured for this domain")
      end

      default = ::PlaceOS::Model::SignageAIProvider.default_for(authority.id)

      Capabilities.new(
        enabled: true,
        providers: rows.map { |row| ImageGen::Adapter.for(row).capabilities },
        default_provider_id: default.try(&.id.to_s),
        logo_layer: !brand_kit.try(&.logo_upload_id).nil?,
        quota: remaining_quota(default),
      )
    end

    # start a generate
    @[AC::Route::POST("/generate", body: :params, status_code: HTTP::Status::ACCEPTED)]
    def generate(params : GenerateParams) : JobResponse
      raise Error::ImageGen::NotConfigured.new("the feature is switched off") if SIGNAGE_AI_DISABLED
      raise Error::ModelValidation.new([Error::Field.new(:prompt, "is required")]) if params.prompt.blank?

      start_job(
        kind: ImageGen::Kind::Generate,
        prompt: params.prompt,
        aspect: params.aspect_ratio,
        quality: params.quality,
        candidates: params.candidates,
        references: params.references,
        include_logo: params.include_logo,
        text_layer: params.add_text_with_layer,
        words: params.words,
        provider_id: params.provider_id,
        model: params.model,
        group_id: params.group_id,
        idempotency_key: params.idempotency_key,
      )
    end

    # start an edit, or a refine of an earlier job
    @[AC::Route::POST("/edit", body: :params, status_code: HTTP::Status::ACCEPTED)]
    def edit(params : EditParams) : JobResponse
      raise Error::ImageGen::NotConfigured.new("the feature is switched off") if SIGNAGE_AI_DISABLED
      raise Error::ModelValidation.new([Error::Field.new(:prompt, "is required")]) if params.prompt.blank?
      raise Error::ModelValidation.new([Error::Field.new(:source_upload_id, "is required")]) if params.source_upload_id.blank?

      source = readable_upload(params.source_upload_id, params.source_item_id)

      parent = if (parent_id = params.parent_job_id)
                 job = ::PlaceOS::Model::SignageAIJob.find?(parent_id)
                 raise Error::NotFound.new("no such parent job") if job.nil? || job.authority_id != authority.id
                 job
               end

      start_job(
        kind: ImageGen::Kind::Edit,
        prompt: params.prompt,
        aspect: params.aspect_ratio,
        quality: params.quality,
        candidates: params.candidates,
        references: params.references,
        include_logo: params.include_logo,
        text_layer: params.add_text_with_layer,
        words: params.words,
        provider_id: params.provider_id,
        model: params.model,
        group_id: params.group_id,
        idempotency_key: params.idempotency_key,
        source: source,
        parent: parent,
      )
    end

    # long poll: holds until the job changes past `since`, or `wait` runs out
    @[AC::Route::GET("/jobs/:id")]
    def show_job(
      @[AC::Param::Info(description: "seconds to hold the request open, 0 to answer immediately", example: "25")]
      wait : Int32 = 0,
      @[AC::Param::Info(description: "the version the caller already has", example: "3")]
      since : Int32? = nil,
    ) : JobResponse
      job = current_job
      return JobResponse.new(job) if wait <= 0 || job.final?

      deadline = Time.utc + Math.min(wait, MAX_WAIT).seconds
      known = since || job.version

      while Time.utc < deadline
        sleep POLL_INTERVAL
        fresh = on_primary { ::PlaceOS::Model::SignageAIJob.find?(job.id.as(UUID)) }
        next if fresh.nil?
        job = fresh
        break if job.version > known || job.final?
      end

      JobResponse.new(job)
    end

    # the caller's recent jobs, for the recent generations list
    @[AC::Route::GET("/jobs")]
    def index_jobs(
      @[AC::Param::Info(description: "only the caller's own jobs", example: "true")]
      mine : Bool = true,
      limit : Int32 = 20,
    ) : Array(JobResponse)
      limit = limit.clamp(1, 100)

      query = ::PlaceOS::Model::SignageAIJob.where(authority_id: authority.id.as(String))
      if mine
        query = query.where(user_id: current_user.id.as(String))
      else
        check_support
      end

      query
        .where("created_at > ?", 7.days.ago)
        .order(created_at: :desc)
        .limit(limit)
        .to_a
        .map { |job| JobResponse.new(job) }
    end

    # ask a running job to stop. Calls already with a vendor run to completion.
    @[AC::Route::POST("/jobs/:id/cancel")]
    def cancel : JobResponse
      job = current_job
      raise Error::Forbidden.new unless job.user_id == current_user.id || user_support?

      unless job.final?
        job.cancel_requested = true
        job.version = job.version + 1
        job.save
      end

      JobResponse.new(job)
    end

    # record that a candidate became a media item, so the sweep leaves it alone
    @[AC::Route::POST("/jobs/:id/claim", body: :params)]
    def claim(params : ClaimParams) : JobResponse
      job = current_job
      raise Error::Forbidden.new unless job.user_id == current_user.id || user_support?

      item = ::PlaceOS::Model::Playlist::Item.find!(params.item_id)
      raise Error::Forbidden.new("item belongs to another domain") unless item.authority_id == authority.id
      raise Error::ModelValidation.new([Error::Field.new(:item_id, "does not use this image")]) unless item.media_id == params.upload_id

      index = job.images.index { |image| image["upload_id"]?.try(&.as_s?) == params.upload_id }
      raise Error::NotFound.new("that image is not part of this job") if index.nil?

      upload = ::PlaceOS::Model::Upload.find?(params.upload_id)
      if upload
        tags = upload.tags.reject { |tag| tag == ImageGen::Store::CANDIDATE_TAG }
        tags << "ai-claimed" unless tags.includes?("ai-claimed")
        upload.tags = tags
        upload.save
      end

      entry = job.images[index].as_h
      entry["item_id"] = JSON::Any.new(item.id.as(String))
      ::PlaceOS::Model::SignageAIJob.bump_image(job.id.as(UUID), index, entry)

      JobResponse.new(::PlaceOS::Model::SignageAIJob.find!(job.id.as(UUID)))
    end

    # spend per provider and model, for the Backoffice usage tab
    @[AC::Route::GET("/usage")]
    def usage(
      @[AC::Param::Info(description: "unix seconds, defaults to 30 days ago")]
      from : Int64? = nil,
      @[AC::Param::Info(description: "unix seconds, defaults to now")]
      to : Int64? = nil,
    ) : Array(::PlaceOS::Model::SignageAIJob::UsageRow)
      check_support

      start = from ? Time.unix(from) : 30.days.ago
      finish = to ? Time.unix(to) : Time.utc
      ::PlaceOS::Model::SignageAIJob.usage(authority.id.as(String), start, finish)
    end

    # Internals
    ###############################################################################################

    MAX_WAIT      = 25
    POLL_INTERVAL = 500.milliseconds

    private def disabled(reason : String) : Capabilities
      Capabilities.new(
        enabled: false,
        providers: [] of ImageGen::ProviderCapabilities,
        default_provider_id: nil,
        quota: {user_remaining_today: nil, domain_remaining_month: nil},
        reason: reason,
      )
    end

    private def brand_kit : ImageGen::Prompt::BrandKit?
      zone_id = support_org_zone_id
      return nil unless zone_id
      metadata = ::PlaceOS::Model::Metadata.build_metadata(zone_id, "signage_ai")["signage_ai"]?
      ImageGen::Prompt::BrandKit.parse(metadata.try(&.details))
    rescue ex
      Log.warn(exception: ex) { "could not read the signage_ai brand kit" }
      nil
    end

    private def quotas_for(row : ::PlaceOS::Model::SignageAIProvider?) : Tuple(Int32, Int32)
      user = row.try(&.quota("user_per_day")) || SIGNAGE_AI_USER_PER_DAY
      domain = row.try(&.quota("domain_per_month")) || SIGNAGE_AI_DOMAIN_PER_MONTH
      {user, domain}
    end

    private def remaining_quota(row : ::PlaceOS::Model::SignageAIProvider?)
      user_limit, domain_limit = quotas_for(row)
      used_today = ::PlaceOS::Model::SignageAIJob.sum_candidates(current_user.id.as(String), 1.day.ago)
      used_month = ::PlaceOS::Model::SignageAIJob.sum_candidates_for_authority(authority.id.as(String), 30.days.ago)

      {
        user_remaining_today:   Math.max(0, user_limit - used_today),
        domain_remaining_month: Math.max(0, domain_limit - used_month),
      }
    end

    # An upload the caller may use as a source or a reference: one they own, or
    # one behind a media item in this domain they can read. Uploads carry no
    # authority of their own, so an item is how a shared image is proved.
    private def readable_upload(upload_id : String, item_id : String? = nil) : ::PlaceOS::Model::Upload
      upload = ::PlaceOS::Model::Upload.find?(upload_id)
      raise Error::NotFound.new("no such upload") if upload.nil?

      return upload if upload.uploaded_by == current_user.id
      return upload if user_support?

      raise Error::ImageGen::Permission.new("this image needs the media item it belongs to") if item_id.nil?

      item = ::PlaceOS::Model::Playlist::Item.find?(item_id)
      raise Error::ImageGen::Permission.new("no such media item") if item.nil?
      raise Error::ImageGen::Permission.new("that item belongs to another domain") unless item.authority_id == authority.id
      unless item.media_id == upload_id || item.thumbnail_id == upload_id
        raise Error::ImageGen::Permission.new("that item does not use this image")
      end

      groups = ::PlaceOS::Model::GroupPlaylistItem.where(playlist_item_id: item.id).to_a.map(&.group_id)
      raise Error::ImageGen::Permission.new("that item is not shared with you") if groups.empty?

      permissions = effective_permissions_for(current_user, groups)
      raise Error::ImageGen::Permission.new("that item is not shared with you") unless permissions.read?

      upload
    end

    # The group a non-admin caller is acting in: they need Create on it, and it
    # has to be a signage group, the same test sharing uses.
    private def check_create_permission(group_id : UUID?) : Nil
      return if user_support?

      raise Error::Forbidden.new("group_id required") if group_id.nil?

      group = ::PlaceOS::Model::Group.find?(group_id)
      raise Error::Forbidden.new("no such group") if group.nil?
      raise Error::Forbidden.new("group must be in the same authority") unless group.authority_id == authority.id
      raise Error::Forbidden.new("group must participate in the 'signage' subsystem") unless group.subsystems.includes?("signage")

      permissions = group_memberships(current_user)[group_id]? || ::PlaceOS::Model::Permissions::None
      raise Error::Forbidden.new("missing Create permission on the target group") unless permissions.create?
    end

    private def start_job(
      kind : ImageGen::Kind,
      prompt : String,
      aspect : String,
      quality : String,
      candidates : Int32,
      references : Array(String),
      include_logo : Bool,
      text_layer : Bool,
      words : String?,
      provider_id : UUID?,
      model : String?,
      group_id : UUID?,
      idempotency_key : String?,
      source : ::PlaceOS::Model::Upload? = nil,
      parent : ::PlaceOS::Model::SignageAIJob? = nil,
    ) : JobResponse
      raise Error::ModelValidation.new([Error::Field.new(:aspect_ratio, "must be one of #{ImageGen::ASPECTS.join(", ")}")]) unless ImageGen.aspect_valid?(aspect)
      candidates = candidates.clamp(1, ImageGen::MAX_CANDIDATES)

      check_create_permission(group_id)

      # a repeat of a submission already accepted returns the same job rather
      # than spending again
      if (key = idempotency_key.presence)
        existing = on_primary do
          ::PlaceOS::Model::SignageAIJob.where(user_id: current_user.id.as(String), idempotency_key: key).first?
        end
        return JobResponse.new(existing) if existing
      end

      row = if provider_id
              found = ::PlaceOS::Model::SignageAIProvider.find?(provider_id)
              raise Error::NotFound.new("no such provider") if found.nil?
              unless found.authority_id.nil? || found.authority_id == authority.id
                raise Error::Forbidden.new("that provider belongs to another domain")
              end
              found
            else
              ::PlaceOS::Model::SignageAIProvider.default_for(authority.id)
            end
      raise Error::ImageGen::NotConfigured.new("no AI provider is configured for this domain") if row.nil?
      raise Error::ImageGen::NotConfigured.new("that provider is switched off") unless row.enabled

      storage = begin
        ::PlaceOS::Model::Storage.storage_or_default(authority.id)
      rescue ex
        raise Error::ImageGen::NotConfigured.new("no upload storage is configured for this domain")
      end

      user_limit, domain_limit = quotas_for(row)
      used_today = ::PlaceOS::Model::SignageAIJob.sum_candidates(current_user.id.as(String), 1.day.ago)
      raise Error::ImageGen::Quota.new("you have used your image allowance for today") if used_today + candidates > user_limit
      used_month = ::PlaceOS::Model::SignageAIJob.sum_candidates_for_authority(authority.id.as(String), 30.days.ago)
      raise Error::ImageGen::Quota.new("this domain has used its image allowance for the month") if used_month + candidates > domain_limit

      adapter = ImageGen::Adapter.for(row)
      chosen_model = model || row.default_model || adapter.capabilities.default_model
      raise Error::ImageGen::NotConfigured.new("no model configured for #{row.name}") if chosen_model.nil?

      allowed = adapter.capabilities.models.map(&.id)
      raise Error::ModelValidation.new([Error::Field.new(:model, "is not available on this provider")]) unless allowed.includes?(chosen_model)

      reference_ids = references.first(8).map { |id| readable_upload(id).id.as(String) }
      if include_logo && (logo = brand_kit.try(&.logo_upload_id).presence)
        reference_ids << logo unless reference_ids.includes?(logo)
      end

      history = parent ? (parent.chain.compact_map(&.prompt) + [parent.prompt].compact) : [] of String

      text = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
        brief: parent ? (history.first? || prompt) : prompt,
        aspect: aspect,
        text_mode: text_layer ? ImageGen::Prompt::TextMode::Layer : ImageGen::Prompt::TextMode::Model,
        include_logo: include_logo,
        brand: brand_kit,
        words: words,
        history: parent ? history[1..]? || [] of String : [] of String,
        instruction: parent ? prompt : nil,
      ))

      request = ImageGen::AdapterRequest.new(
        kind: kind,
        prompt: text,
        aspect: aspect,
        quality: quality,
        candidates: candidates,
        model: chosen_model,
      )

      # every vendor call needs a slot, taken before anything is written, so a
      # busy replica never leaves a job nobody is working on
      calls = adapter.calls_for(candidates)
      unless ImageGen.slots.try_reserve(calls)
        raise Error::ImageGen::Busy.new("too many images are being generated right now, try again in a moment")
      end

      job = ::PlaceOS::Model::SignageAIJob.new(
        authority_id: authority.id.as(String),
        provider_id: row.id.as(UUID),
        provider_type: row.provider.to_s,
        model: chosen_model,
        user_id: current_user.id,
        user_email: current_user.email.to_s,
        user_name: current_user.name,
        parent_job_id: parent.try(&.id.as(UUID)),
        kind: kind == ImageGen::Kind::Edit ? ::PlaceOS::Model::SignageAIJob::Kind::Edit : ::PlaceOS::Model::SignageAIJob::Kind::Generate,
        candidates: candidates,
        idempotency_key: idempotency_key.presence,
        prompt: prompt,
      )
      job.request = JSON::Any.new({
        "aspect_ratio" => JSON::Any.new(aspect),
        "quality"      => JSON::Any.new(quality),
        "include_logo" => JSON::Any.new(include_logo),
        "text_layer"   => JSON::Any.new(text_layer),
        "references"   => JSON::Any.new(reference_ids.map { |id| JSON::Any.new(id) }),
      })
      job.result = JSON::Any.new({
        "images" => JSON::Any.new(Array(JSON::Any).new(candidates) { JSON::Any.new(nil) }),
      })
      job.upload_ids = reference_ids

      unless job.save
        ImageGen.slots.release(calls)
        raise Error::ModelValidation.new(job.errors)
      end

      context = ImageGen::Runner::Context.new(
        job_id: job.id.as(UUID),
        authority_id: authority.id.as(String),
        hostname: request_hostname,
        user: current_user,
        storage: storage,
        adapter: adapter,
        request: request,
        source_upload_id: source.try(&.id.as(String)),
        reference_upload_ids: reference_ids,
      )

      spawn { ImageGen::Runner.run(context) }

      JobResponse.new(job)
    end

    private def request_hostname : String
      request.hostname.presence || authority.domain
    end
  end
end
