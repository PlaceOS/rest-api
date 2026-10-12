require "digest/sha256"
require "placeos-models/signage_ai_job"
require "placeos-models/signage_ai_provider"
require "placeos-models/upload"
require "placeos-models/zone"

require "./application"

module PlaceOS::Api
  # AI editing of a level's SVG map, with the signage AI provider rows.
  #
  # The editor posts the instruction and the context it built from the map (the
  # element index, the shortlisted subtrees, the annotations and a marked up
  # snapshot by upload id). The answer is a list of operations the editor
  # applies, reviews and saves itself; nothing here reads or writes the map.
  # One job is one vendor call, long polled through `jobs/:id` as signage is.
  @[AC::MCP(hide: true)]
  class MapAI < Application
    include Utils::Permissions
    include Utils::GroupPermissions
    include Utils::AIJobs

    base "/api/engine/v2/maps/ai"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:capabilities, :show_job, :index_jobs, :usage]
    before_action :can_write, only: [:edit, :cancel, :resolve]

    ###############################################################################################

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

    @[AC::Route::Filter(:before_action, only: [:show_job, :cancel, :resolve])]
    def find_current_job(id : UUID)
      Log.context.set(map_ai_job: id.to_s)
      job = authority_job(id, authority.id.as(String))
      raise Error::NotFound.new("no such job") unless job.kind.map_edit?
      @current_job = job
    end

    getter! current_job : ::PlaceOS::Model::SignageAIJob

    # Requests
    ###############################################################################################

    struct EditParams
      include JSON::Serializable

      getter zone_id : String = ""
      getter instruction : String = ""
      # placeos.map-ai-context/1, built by the editor
      getter context : JSON::Any? = nil
      getter markup_upload_id : String? = nil
      getter parent_job_id : UUID? = nil
      getter provider_id : UUID? = nil
      getter model : String? = nil
      getter idempotency_key : String? = nil
    end

    DECISIONS = %w(applied partial rejected refined abandoned)

    struct ResolveParams
      include JSON::Serializable

      getter decision : String = ""
      getter accepted_op_ids : Array(String) = [] of String
      getter rejected_op_ids : Array(String) = [] of String
      getter reasons : JSON::Any? = nil
      getter saved_upload_id : String? = nil
    end

    # Responses
    ###############################################################################################

    struct Capabilities
      include JSON::Serializable

      getter? enabled : Bool
      getter reason : String?
      getter providers : Array(Llm::ProviderCapabilities)
      getter default_provider_id : String?
      getter quota : NamedTuple(user_remaining_today: Int32?, domain_remaining_month: Int32?)
      getter limits : NamedTuple(max_context_bytes: Int32, max_ops: Int32, max_instruction_chars: Int32)

      def initialize(@enabled, @providers, @default_provider_id, @quota, @reason = nil)
        @limits = {
          max_context_bytes:     MAP_AI_MAX_CONTEXT_BYTES,
          max_ops:               MAP_AI_MAX_OPS,
          max_instruction_chars: MAP_AI_MAX_INSTRUCTION_CHARS,
        }
      end
    end

    # A job as the editor sees it. `ops` are the model's operations exactly as
    # returned; `server_issues` names the ones the server could not accept.
    struct JobResponse
      include JSON::Serializable

      getter id : String
      getter state : String
      getter kind : String
      getter zone_id : String?
      getter provider : String?
      getter model : String?
      getter parent_job_id : String?
      getter version : Int32
      getter instruction : String?
      getter markup_upload_id : String?
      getter schema_version : Int64?
      getter summary : String?
      getter ops : Array(JSON::Any)
      # keyed by op id: `op-N`, N the op's 1-based position in `ops`
      getter server_issues : Hash(String, String)
      getter questions : Array(JSON::Any)
      getter usage : JSON::Any?
      getter resolution : JSON::Any?
      getter error_kind : String?
      getter error_message : String?
      getter cost_units : Float64?
      getter latency_ms : Int64?
      getter created_at : Int64?
      getter finished_at : Int64?

      def initialize(job : ::PlaceOS::Model::SignageAIJob)
        result = job.result
        request = job.request
        @id = job.id.to_s
        @state = job.state.to_s
        @kind = job.kind.to_s
        @zone_id = request["zone_id"]?.try(&.as_s?)
        @provider = job.provider_type
        @model = job.model
        @parent_job_id = job.parent_job_id.try(&.to_s)
        @version = job.version
        @instruction = job.prompt
        @markup_upload_id = request["markup_upload_id"]?.try(&.as_s?)
        @schema_version = result["schema_version"]?.try(&.as_i64?)
        @summary = result["summary"]?.try(&.as_s?)
        @ops = result["ops"]?.try(&.as_a?) || [] of JSON::Any
        @server_issues = {} of String => String
        if (issues = result["server_issues"]?.try(&.as_h?))
          issues.each { |id, reason| @server_issues[id] = reason.as_s? || reason.to_s }
        end
        @questions = result["questions"]?.try(&.as_a?) || [] of JSON::Any
        @usage = result["usage"]?
        @resolution = result["resolution"]?
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
      return disabled("the feature is switched off") if MAP_AI_DISABLED

      rows = ::PlaceOS::Model::SignageAIProvider.available_for(authority.id)
      return disabled("no AI provider is configured for this domain") if rows.empty?

      usable = rows.select { |row| Llm::Adapter.supports?(row) }
      return disabled("the configured AI provider cannot edit maps yet") if usable.empty?

      default = default_row(usable)

      Capabilities.new(
        enabled: true,
        providers: usable.map { |row| Llm::Adapter.for(row).capabilities },
        default_provider_id: default.id.to_s,
        quota: remaining_quota(default),
      )
    end

    # ask for operations that carry out an instruction on a level's map
    @[AC::Route::POST("/edit", body: :params, status_code: HTTP::Status::ACCEPTED)]
    def edit(params : EditParams) : JobResponse
      raise Error::ImageGen::NotConfigured.new("the feature is switched off") if MAP_AI_DISABLED

      instruction = params.instruction.strip
      raise Error::ModelValidation.new([Error::Field.new(:instruction, "is required")]) if instruction.empty?
      if instruction.size > MAP_AI_MAX_INSTRUCTION_CHARS
        raise Error::ModelValidation.new([Error::Field.new(:instruction, "is longer than #{MAP_AI_MAX_INSTRUCTION_CHARS} characters")])
      end
      raise Error::ModelValidation.new([Error::Field.new(:zone_id, "is required")]) if params.zone_id.blank?

      zone = ::PlaceOS::Model::Zone.find?(params.zone_id)
      raise Error::NotFound.new("no such zone") if zone.nil? || !zone_visible?(zone)
      raise Error::Forbidden.new("you cannot change this zone's map") unless zone_updatable?(zone)

      context = params.context
      if context.nil? || context.as_h?.nil?
        raise Error::ModelValidation.new([Error::Field.new(:context, "is required")])
      end
      unless context["schema"]?.try(&.as_s?) == Llm::Prompt::CONTEXT_SCHEMA
        raise Error::ModelValidation.new([Error::Field.new(:context, "must be #{Llm::Prompt::CONTEXT_SCHEMA}")])
      end
      index = context["index"]?.try(&.as_a?)
      raise Error::ModelValidation.new([Error::Field.new(:context, "needs an index")]) if index.nil?
      context_body = context.to_json
      if context_body.bytesize > MAP_AI_MAX_CONTEXT_BYTES
        raise Error::ModelValidation.new([Error::Field.new(:context, "is larger than #{MAP_AI_MAX_CONTEXT_BYTES // 1024}KB")])
      end

      # a repeat of a submission already accepted returns the same job
      if (key = params.idempotency_key.presence) && (existing = job_for_key(key))
        return JobResponse.new(existing)
      end

      row = if (provider_id = params.provider_id)
              found = ::PlaceOS::Model::SignageAIProvider.find?(provider_id)
              raise Error::NotFound.new("no such provider") if found.nil?
              unless found.authority_id.nil? || found.authority_id == authority.id
                raise Error::Forbidden.new("that provider belongs to another domain")
              end
              found
            else
              usable = ::PlaceOS::Model::SignageAIProvider.available_for(authority.id).select { |entry| Llm::Adapter.supports?(entry) }
              usable.empty? ? nil : default_row(usable)
            end
      raise Error::ImageGen::NotConfigured.new("no AI provider is configured for this domain") if row.nil?
      raise Error::ImageGen::NotConfigured.new("that provider is switched off") unless row.enabled

      adapter = Llm::Adapter.for(row)
      chosen_model = params.model.presence || adapter.text_model

      user_limit, domain_limit = quotas_for(row)
      used_today = ::PlaceOS::Model::SignageAIJob.sum_candidates(current_user.id.as(String), 1.day.ago, ::PlaceOS::Model::SignageAIJob::Kind::MapEdit)
      raise Error::ImageGen::Quota.new("you have used your map editing allowance for today") if used_today + 1 > user_limit
      used_month = ::PlaceOS::Model::SignageAIJob.sum_candidates_for_authority(authority.id.as(String), 30.days.ago, ::PlaceOS::Model::SignageAIJob::Kind::MapEdit)
      raise Error::ImageGen::Quota.new("this domain has used its map editing allowance for the month") if used_month + 1 > domain_limit

      parent = if (parent_id = params.parent_job_id)
                 found = ::PlaceOS::Model::SignageAIJob.find?(parent_id)
                 if found.nil? || found.authority_id != authority.id || !found.kind.map_edit?
                   raise Error::NotFound.new("no such parent job")
                 end
                 found
               end
      history = history_for(parent)

      markup = params.markup_upload_id.presence.try { |upload_id| markup_upload(upload_id) }

      # the slot is taken after every check that can raise and before anything
      # is written, so a busy replica never leaves a job nobody is working on
      unless Llm.slots.try_reserve(1)
        raise Error::ImageGen::Busy.new("too many map edits are running right now, try again in a moment")
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
        kind: ::PlaceOS::Model::SignageAIJob::Kind::MapEdit,
        candidates: 1,
        idempotency_key: params.idempotency_key.presence,
        prompt: instruction,
      )
      job.request = JSON::Any.new({
        "zone_id"          => JSON::Any.new(zone.id.as(String)),
        "markup_upload_id" => JSON::Any.new(markup.try(&.id.as(String))),
        "provider_id"      => JSON::Any.new(row.id.to_s),
        "model"            => JSON::Any.new(chosen_model),
        "context_schema"   => JSON::Any.new(Llm::Prompt::CONTEXT_SCHEMA),
        "context_bytes"    => JSON::Any.new(context_body.bytesize.to_i64),
        "context_sha256"   => JSON::Any.new(Digest::SHA256.hexdigest(context_body)),
        "element_count"    => JSON::Any.new(index.size.to_i64),
      })
      job.upload_ids = markup ? [markup.id.as(String)] : [] of String

      unless job.save
        Llm.slots.release

        # a concurrent submission of the same key got there first: the partial
        # unique index is what enforces the key, so answer with the job that won
        if (key = params.idempotency_key.presence) && (existing = job_for_key(key))
          return JobResponse.new(existing)
        end

        raise Error::ModelValidation.new(job.errors)
      end

      runner_context = Llm::Runner::Context.new(
        job_id: job.id.as(UUID),
        authority_id: authority.id.as(String),
        user_id: current_user.id,
        adapter: adapter,
        model: chosen_model,
        context: context,
        instruction: instruction,
        history: history,
        markup_upload_id: markup.try(&.id.as(String)),
      )

      spawn { Llm::Runner.run(runner_context) }

      JobResponse.new(job)
    end

    # long poll: holds until the job changes past `since`, or `wait` runs out
    @[AC::Route::GET("/jobs/:id")]
    def show_job(
      @[AC::Param::Info(description: "seconds to hold the request open, 0 to answer immediately", example: "25")]
      wait : Int32 = 0,
      @[AC::Param::Info(description: "the version the caller already has", example: "3")]
      since : Int32? = nil,
    ) : JobResponse
      JobResponse.new(await_job_change(current_job, wait, since))
    end

    # recent map edit jobs
    @[AC::Route::GET("/jobs")]
    def index_jobs(
      @[AC::Param::Info(description: "only the caller's own jobs", example: "true")]
      mine : Bool = true,
      @[AC::Param::Info(description: "only jobs against this zone", example: "zone-1234")]
      zone_id : String? = nil,
      @[AC::Param::Info(description: "map_edit; another kind lists that kind instead", example: "map_edit")]
      kind : String = "map_edit",
      limit : Int32 = 20,
    ) : Array(JobResponse)
      limit = limit.clamp(1, 100)

      parsed = ::PlaceOS::Model::SignageAIJob::Kind.parse?(kind)
      raise Error::ModelValidation.new([Error::Field.new(:kind, "must be one of generate, edit, map_edit")]) if parsed.nil?

      query = ::PlaceOS::Model::SignageAIJob
        .where(authority_id: authority.id.as(String))
        .where("kind = ?", ::PlaceOS::Model::SignageAIJob.kind_label(parsed))
      if mine
        query = query.where(user_id: current_user.id.as(String))
      else
        check_support
      end
      if (zone = zone_id.presence)
        query = query.where("request->>'zone_id' = ?", zone)
      end

      query
        .where("created_at > ?", 7.days.ago)
        .order(created_at: :desc)
        .limit(limit)
        .to_a
        .map { |job| JobResponse.new(job) }
    end

    # ask a running job to stop. A call already with the vendor runs to completion.
    @[AC::Route::POST("/jobs/:id/cancel")]
    def cancel : JobResponse
      job = current_job
      raise Error::Forbidden.new unless job.user_id == current_user.id || user_support?

      unless job.final?
        job.cancel_requested = true
        job.save
        ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))
        job = ::PlaceOS::Model::SignageAIJob.find!(job.id.as(UUID))
      end

      JobResponse.new(job)
    end

    # record what the person did with the answer: which ops were applied or
    # rejected and why, and the upload the saved map became
    @[AC::Route::POST("/jobs/:id/resolve", body: :params)]
    def resolve(params : ResolveParams) : JobResponse
      job = current_job
      raise Error::Forbidden.new unless job.user_id == current_user.id || user_support?
      unless DECISIONS.includes?(params.decision)
        raise Error::ModelValidation.new([Error::Field.new(:decision, "must be one of #{DECISIONS.join(", ")}")])
      end
      raise Error::ModelValidation.new([Error::Field.new(:id, "the job has not finished")]) unless job.final?

      result = job.result.as_h.dup
      result["resolution"] = JSON::Any.new({
        "decision"        => JSON::Any.new(params.decision),
        "accepted_op_ids" => JSON::Any.new(params.accepted_op_ids.map { |id| JSON::Any.new(id) }),
        "rejected_op_ids" => JSON::Any.new(params.rejected_op_ids.map { |id| JSON::Any.new(id) }),
        "reasons"         => params.reasons || JSON::Any.new(nil),
        "saved_upload_id" => JSON::Any.new(params.saved_upload_id.presence),
        "resolved_at"     => JSON::Any.new(Time.utc.to_unix),
        "resolved_by"     => JSON::Any.new(current_user.id),
      })
      job.result = JSON::Any.new(result)
      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))

      JobResponse.new(::PlaceOS::Model::SignageAIJob.find!(job.id.as(UUID)))
    end

    # map edit spend per provider and model
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
      ::PlaceOS::Model::SignageAIJob.usage(authority.id.as(String), start, finish, ::PlaceOS::Model::SignageAIJob::Kind::MapEdit)
    end

    # Internals
    ###############################################################################################

    # how recently an upload must have been made to count as the throwaway
    # snapshot of this request rather than a file from the library
    MARKUP_TAG_WINDOW = 15.minutes

    IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}

    private def disabled(reason : String) : Capabilities
      Capabilities.new(
        enabled: false,
        providers: [] of Llm::ProviderCapabilities,
        default_provider_id: nil,
        quota: {user_remaining_today: nil, domain_remaining_month: nil},
        reason: reason,
      )
    end

    # the domain's default row when it can edit maps, else the first that can
    private def default_row(usable : Array(::PlaceOS::Model::SignageAIProvider)) : ::PlaceOS::Model::SignageAIProvider
      default = ::PlaceOS::Model::SignageAIProvider.default_for(authority.id)
      if default && usable.any? { |row| row.id == default.id }
        default
      else
        usable.first
      end
    end

    # A zone outside the caller's org tree reads as unknown to anyone but support.
    private def zone_visible?(zone : ::PlaceOS::Model::Zone) : Bool
      return true if user_support?
      org_zone_id = support_org_zone_id
      return true if org_zone_id.nil?
      zone.root_zone_id == org_zone_id
    end

    private def quotas_for(row : ::PlaceOS::Model::SignageAIProvider?) : Tuple(Int32, Int32)
      user = row.try(&.quota("map_user_per_day")) || MAP_AI_USER_PER_DAY
      domain = row.try(&.quota("map_domain_per_month")) || MAP_AI_DOMAIN_PER_MONTH
      {user, domain}
    end

    private def remaining_quota(row : ::PlaceOS::Model::SignageAIProvider?)
      user_limit, domain_limit = quotas_for(row)
      kind = ::PlaceOS::Model::SignageAIJob::Kind::MapEdit
      used_today = ::PlaceOS::Model::SignageAIJob.sum_candidates(current_user.id.as(String), 1.day.ago, kind)
      used_month = ::PlaceOS::Model::SignageAIJob.sum_candidates_for_authority(authority.id.as(String), 30.days.ago, kind)

      {
        user_remaining_today:   Math.max(0, user_limit - used_today),
        domain_remaining_month: Math.max(0, domain_limit - used_month),
      }
    end

    # The marked up snapshot: the caller's own image, under the size cap, tagged
    # for the sweep when it was uploaded for this request.
    private def markup_upload(upload_id : String) : ::PlaceOS::Model::Upload
      upload = ::PlaceOS::Model::Upload.find?(upload_id)
      raise Error::NotFound.new("no such upload") if upload.nil?
      raise Error::ImageGen::Permission.new("that image is not yours") unless upload.uploaded_by == current_user.id
      if upload.file_size > SIGNAGE_AI_MAX_IMAGE_BYTES
        raise Error::ImageGen::Permission.new("that image is larger than #{SIGNAGE_AI_MAX_IMAGE_BYTES // (1024 * 1024)}MB")
      end
      unless IMAGE_EXTENSIONS.includes?(File.extname(upload.file_name).downcase)
        raise Error::ImageGen::Permission.new("that file is not a png, jpeg or webp image")
      end

      if upload.tags.empty? && upload.created_at > MARKUP_TAG_WINDOW.ago
        upload.tags = [ImageGen::Store::MARKUP_TAG]
        upload.save
      end
      upload
    end

    # The map edit job already holding the caller's idempotency key. The key
    # is unique per user across every kind, so one held by an image job is a 409.
    private def job_for_key(key : String) : ::PlaceOS::Model::SignageAIJob?
      existing = on_primary do
        ::PlaceOS::Model::SignageAIJob.where(user_id: current_user.id.as(String), idempotency_key: key).first?
      end
      return if existing.nil?
      raise Error::Conflict.new("idempotency key #{key} was used for a #{existing.kind} job") unless existing.kind.map_edit?
      existing
    end

    # The refine chain, oldest first, as the prompt builder takes it.
    private def history_for(parent : ::PlaceOS::Model::SignageAIJob?) : Array(Llm::Prompt::Turn)
      return [] of Llm::Prompt::Turn if parent.nil?

      (parent.chain + [parent]).select(&.kind.map_edit?).map do |job|
        result = job.result
        Llm::Prompt::Turn.new(
          instruction: job.prompt || "",
          ops: result["ops"]?.try(&.as_a?) || [] of JSON::Any,
          summary: result["summary"]?.try(&.as_s?),
          resolution: result["resolution"]?,
        )
      end
    end
  end
end
