require "placeos-models/signage_ai_job"
require "placeos-models/upload"

module PlaceOS::Api::Llm
  # The body of the spawned fiber for a map edit: the vendor call under the
  # slot the request handler reserved, made once more at a larger output
  # budget when the first answer was cut off.
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
        finish(job, started, nil, [] of Result, nil)
        return
      end

      job.state = ::PlaceOS::Model::SignageAIJob::State::Running
      job.started_at = started
      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))

      results = [] of Result
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
        results << answer

        if answer.finish == "length" && !cancelled?(context.job_id)
          answer = context.adapter.complete(request.copy_with(max_output_tokens: MAP_AI_RETRY_OUTPUT_TOKENS))
          results << answer
        end

        if answer.finish == "length"
          raise Error::ImageGen::InvalidResponse.new("the answer was cut off at the output limit, try a smaller change")
        end

        envelope = Ops.parse(answer.text)
        checked = Ops.check(envelope.ops, context.context)

        issues = {} of String => JSON::Any
        checked.issues.each { |id, reason| issues[id] = JSON::Any.new(reason) }

        written = {
          "schema_version" => JSON::Any.new(Schema::VERSION.to_i64),
          "summary"        => JSON::Any.new(envelope.summary),
          "ops"            => JSON::Any.new(checked.ops),
          "server_issues"  => JSON::Any.new(issues),
          "questions"      => JSON::Any.new(envelope.questions.map { |question| JSON::Any.new(question) }),
          "usage"          => JSON::Any.new(usage_of(results, context.model)),
        }
      rescue ex
        Log.warn(exception: ex) { "map AI vendor call failed" }
        failure = ex
      end

      fresh = ::PlaceOS::Model::SignageAIJob.find?(context.job_id)
      finish(fresh, started, written, results, failure) if fresh
    rescue ex
      Log.error(exception: ex) { "map AI job failed outside the vendor call" }
      if (job = ::PlaceOS::Model::SignageAIJob.find?(context.job_id))
        finish(job, started || Time.utc, nil, [] of Result, ex)
      end
    ensure
      Llm.slots.release
    end

    private def self.cancelled?(job_id : UUID) : Bool
      ::PlaceOS::Model::SignageAIJob.find?(job_id).try(&.cancel_requested) || false
    end

    # The marked up snapshot the person attached, read back from storage.
    private def self.markup_image(upload_id : String?) : ImagePart?
      return unless upload_id
      upload = ::PlaceOS::Model::Upload.find?(upload_id)
      raise Error::ImageGen::Vendor.new("the markup image is gone") if upload.nil?
      reference = ImageGen::Store.fetch(upload)
      ImagePart.new(bytes: reference.bytes, mime: reference.mime)
    end

    # Token counts summed over every attempt; `finish` is the last attempt's.
    private def self.usage_of(results : Array(Result), model : String) : Hash(String, JSON::Any)
      {
        "input_tokens"  => JSON::Any.new(sum_tokens(results, &.input_tokens)),
        "output_tokens" => JSON::Any.new(sum_tokens(results, &.output_tokens)),
        "total_tokens"  => JSON::Any.new(sum_tokens(results, &.total_tokens)),
        "finish"        => JSON::Any.new(results.last?.try(&.finish)),
        "attempts"      => JSON::Any.new(results.size.to_i64),
        "model"         => JSON::Any.new(model),
      }
    end

    private def self.sum_tokens(results : Array(Result), & : Result -> Int64?) : Int64?
      counted = results.compact_map { |result| yield result }
      counted.empty? ? nil : counted.sum
    end

    private def self.finish(
      job : ::PlaceOS::Model::SignageAIJob,
      started : Time,
      written : Hash(String, JSON::Any)?,
      results : Array(Result),
      failure : Exception?,
    ) : Nil
      job.finished_at = Time.utc
      job.latency_ms = (Time.utc - started).total_milliseconds.to_i64
      if (tokens = sum_tokens(results, &.total_tokens))
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
        message:  "map AI job finished",
        state:    job.state.to_s,
        ops:      written.try(&.["ops"]?).try(&.as_a?).try(&.size),
        flagged:  written.try(&.["server_issues"]?).try(&.as_h?).try(&.size),
        attempts: results.size,
        tokens:   job.cost_units,
        latency:  job.latency_ms,
        model:    job.model,
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
