require "placeos-models/signage_ai_job"
require "placeos-models/upload"

module PlaceOS::Api::Llm
  # The body of the spawned fiber for a map edit: one vendor call under the
  # slot the request handler reserved.
  #
  # Everything it needs is captured before `spawn`: inside the fiber there is
  # no request and `Log.context` is empty. The context the editor posted is
  # held here in memory only; the job row records its size and hash.
  module Runner
    record Context,
      job_id : UUID,
      authority_id : String,
      user_id : String?,
      adapter : Adapter,
      model : String,
      context : JSON::Any,
      instruction : String,
      history : Array(Prompt::Turn) = [] of Prompt::Turn,
      markup_upload_id : String? = nil

    def self.run(context : Context) : Nil
      ::Log.context.set(
        map_ai_job: context.job_id.to_s,
        authority_id: context.authority_id,
        user_id: context.user_id,
      )

      started = Time.utc
      job = ::PlaceOS::Model::SignageAIJob.find?(context.job_id)
      return if job.nil?

      if job.cancel_requested
        finish(job, started, nil, nil, nil)
        return
      end

      job.state = ::PlaceOS::Model::SignageAIJob::State::Running
      job.started_at = started
      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))

      result : Result? = nil
      written : Hash(String, JSON::Any)? = nil
      failure : Exception? = nil

      begin
        request = Prompt.build(Prompt::Options.new(
          context: context.context,
          instruction: context.instruction,
          model: context.model,
          history: context.history,
          image: markup_image(context.markup_upload_id),
        ))

        answer = context.adapter.complete(request)
        result = answer

        if answer.finish == "length"
          raise Error::ImageGen::InvalidResponse.new("the answer was cut off at the output limit, try a smaller change")
        end

        envelope = Ops.parse(answer.text)
        ops = Ops.check(envelope.ops, context.context)

        written = {
          "schema_version" => JSON::Any.new(Schema::VERSION.to_i64),
          "summary"        => JSON::Any.new(envelope.summary),
          "ops"            => JSON::Any.new(ops),
          "questions"      => JSON::Any.new(envelope.questions.map { |question| JSON::Any.new(question) }),
          "usage"          => JSON::Any.new(answer.usage.merge({"model" => JSON::Any.new(context.model)})),
        }
      rescue ex
        Log.warn(exception: ex) { "map AI vendor call failed" }
        failure = ex
      end

      fresh = ::PlaceOS::Model::SignageAIJob.find?(context.job_id)
      finish(fresh, started, written, result, failure) if fresh
    rescue ex
      Log.error(exception: ex) { "map AI job failed outside the vendor call" }
      if (job = ::PlaceOS::Model::SignageAIJob.find?(context.job_id))
        finish(job, started || Time.utc, nil, nil, ex)
      end
    ensure
      Llm.slots.release
    end

    # The marked up snapshot the person attached, read back from storage.
    private def self.markup_image(upload_id : String?) : ImagePart?
      return unless upload_id
      upload = ::PlaceOS::Model::Upload.find?(upload_id)
      raise Error::ImageGen::Vendor.new("the markup image is gone") if upload.nil?
      reference = ImageGen::Store.fetch(upload)
      ImagePart.new(bytes: reference.bytes, mime: reference.mime)
    end

    private def self.finish(
      job : ::PlaceOS::Model::SignageAIJob,
      started : Time,
      written : Hash(String, JSON::Any)?,
      result : Result?,
      failure : Exception?,
    ) : Nil
      job.finished_at = Time.utc
      job.latency_ms = (Time.utc - started).total_milliseconds.to_i64
      if (tokens = result.try(&.total_tokens))
        job.cost_units = tokens.to_f
      end
      job.result = JSON::Any.new(written) if written

      if job.cancel_requested
        job.state = ::PlaceOS::Model::SignageAIJob::State::Cancelled
      elsif written && failure.nil?
        job.state = ::PlaceOS::Model::SignageAIJob::State::Done
      else
        job.state = ::PlaceOS::Model::SignageAIJob::State::Failed
        job.error_kind = failure ? kind_of(failure) : "vendor"
        job.error_message = failure ? message_of(failure) : "no answer was produced"
      end

      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))

      Log.info { {
        message: "map AI job finished",
        state:   job.state.to_s,
        ops:     written.try(&.["ops"]?).try(&.as_a?).try(&.size),
        tokens:  result.try(&.total_tokens),
        latency: job.latency_ms,
        model:   job.model,
      } }
    end

    private def self.kind_of(error : Exception) : String
      case error
      when Error::ImageGen  then error.as(Error::ImageGen).kind
      when IO::TimeoutError then "timeout"
      else                       "vendor"
      end
    end

    # never the vendor's whole body, and never the prompt
    private def self.message_of(error : Exception) : String
      (error.message || error.class.name).lines.first?.to_s[0, 300]
    end
  end
end
