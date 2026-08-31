require "placeos-models/signage_ai_job"
require "placeos-models/storage"
require "placeos-models/user"

module PlaceOS::Api::ImageGen
  # The body of the spawned fiber.
  #
  # Everything it needs is captured before `spawn`: inside the fiber there is no
  # request, `Log.context` is empty and `current_user` does not exist. Candidate
  # results are written back one at a time with an atomic update so a long
  # polling client sees each one land, and so two candidate fibers cannot drop
  # each other's entry.
  module Runner
    # Captured at request time and handed to the fiber.
    record Context,
      job_id : UUID,
      authority_id : String,
      hostname : String,
      user : ::PlaceOS::Model::User,
      storage : ::PlaceOS::Model::Storage,
      adapter : Adapter,
      request : AdapterRequest,
      source_upload_id : String? = nil,
      reference_upload_ids : Array(String) = [] of String

    def self.run(context : Context) : Nil
      ::Log.context.set(
        signage_ai_job: context.job_id.to_s,
        authority_id: context.authority_id,
        user_id: context.user.id,
      )

      # Slots were reserved by the request handler, one per planned vendor call.
      # This is the only thing that hands them back, so every exit path has to
      # drain the ledger. Atomic because the candidate fibers decrement it as
      # they finish, and `swap` makes each drain a one time claim.
      held = Atomic(Int32).new(context.adapter.calls_for(context.request.candidates))

      started = Time.utc
      job = ::PlaceOS::Model::SignageAIJob.find?(context.job_id)
      if job.nil?
        release(held.swap(0))
        return
      end

      job.state = ::PlaceOS::Model::SignageAIJob::State::Running
      job.started_at = started
      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))

      request = hydrate(context)

      produced = 0
      failure : Exception? = nil
      cost = 0.0

      calls = plan(context.adapter, context.request.candidates)
      index_offset = 0
      done = Channel(Nil).new

      calls.each_with_index do |wanted, call_index|
        offset = index_offset
        index_offset += wanted

        spawn do
          begin
            next if cancelled?(context.job_id)

            images = context.adapter.call(request.copy_with(candidates: wanted))

            images.each_with_index do |image, image_index|
              slot = offset + image_index
              next if slot >= context.request.candidates

              stored = Store.put(image, context.storage, context.user, context.hostname, context.job_id.to_s, slot)
              cost += image.cost_units || 0.0
              produced += 1

              ::PlaceOS::Model::SignageAIJob.bump_image(context.job_id, slot, {
                "state"     => JSON::Any.new("done"),
                "index"     => JSON::Any.new(slot.to_i64),
                "upload_id" => JSON::Any.new(stored.upload.id.as(String)),
                "url"       => JSON::Any.new("/api/engine/v2/uploads/#{stored.upload.id}/url"),
                "width"     => stored.width ? JSON::Any.new(stored.width.not_nil!.to_i64) : JSON::Any.new(nil),
                "height"    => stored.height ? JSON::Any.new(stored.height.not_nil!.to_i64) : JSON::Any.new(nil),
                "mime"      => JSON::Any.new(image.mime),
                "bytes"     => JSON::Any.new(image.bytes.size.to_i64),
              })
            end
          rescue ex
            Log.warn(exception: ex) { {message: "signage AI vendor call failed", call: call_index} }
            failure ||= ex
          ensure
            # one release per finished vendor call
            ImageGen.slots.release
            held.sub(1)
            done.send(nil)
          end
        end
      end

      calls.size.times { done.receive }

      release(held.swap(0))

      finish(context, produced, cost, failure, started)
    rescue ex
      # a failure before or between the candidate fibers: the ones that ran gave
      # their slot back in an ensure, the rest never will, so square the ledger
      Log.error(exception: ex) { "signage AI job failed outside a vendor call" }
      fail_job(context.job_id, ex)
      release(held.swap(0)) if held
    end

    # hand back slots this run still holds, never more
    private def self.release(count : Int32) : Nil
      count.times { ImageGen.slots.release } if count > 0
    end

    # Fetch the source and reference bytes once, before any vendor call.
    private def self.hydrate(context : Context) : AdapterRequest
      request = context.request

      if (source_id = context.source_upload_id)
        upload = ::PlaceOS::Model::Upload.find?(source_id)
        raise Error::ImageGen::Vendor.new("the source image is gone") if upload.nil?
        source = Store.fetch(upload)
        request = request.copy_with(source: source)

        # an edit comes back at the size we ask for, so ask for the shape we were
        # given. Without this the aspect the caller picked reframes the poster.
        if (dimensions = Http.dimensions(source.bytes))
          if (size = ImageGen.editable_size(dimensions[0], dimensions[1]))
            request = request.copy_with(size_override: size)
          end
        end
      end

      unless context.reference_upload_ids.empty?
        references = context.reference_upload_ids.compact_map do |id|
          upload = ::PlaceOS::Model::Upload.find?(id)
          upload ? Store.fetch(upload) : nil
        end
        request = request.copy_with(references: references)
      end

      request
    end

    # How many images to ask for per vendor call.
    private def self.plan(adapter : Adapter, candidates : Int32) : Array(Int32)
      per_call = adapter.images_per_call
      per_call = 1 if per_call < 1

      remaining = candidates
      calls = [] of Int32
      while remaining > 0
        take = Math.min(per_call, remaining)
        calls << take
        remaining -= take
      end
      calls
    end

    private def self.cancelled?(job_id : UUID) : Bool
      job = ::PlaceOS::Model::SignageAIJob.find?(job_id)
      job.nil? || job.cancel_requested
    end

    private def self.finish(context : Context, produced : Int32, cost : Float64, failure : Exception?, started : Time) : Nil
      job = ::PlaceOS::Model::SignageAIJob.find?(context.job_id)
      return if job.nil?

      job.finished_at = Time.utc
      job.latency_ms = (Time.utc - started).total_milliseconds.to_i64
      job.cost_units = cost if cost > 0

      if job.cancel_requested
        job.state = ::PlaceOS::Model::SignageAIJob::State::Cancelled
      elsif produced > 0
        # a partial result is still a result: the user picks from what landed
        job.state = ::PlaceOS::Model::SignageAIJob::State::Done
        if failure
          job.error_kind = kind_of(failure)
          job.error_message = message_of(failure)
        end
      elsif failure
        job.state = ::PlaceOS::Model::SignageAIJob::State::Failed
        job.error_kind = kind_of(failure)
        job.error_message = message_of(failure)
      else
        job.state = ::PlaceOS::Model::SignageAIJob::State::Failed
        job.error_kind = "vendor"
        job.error_message = "no images were produced"
      end

      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))

      Log.info { {
        message:  "signage AI job finished",
        state:    job.state.to_s,
        produced: produced,
        calls:    context.request.candidates,
        latency:  job.latency_ms,
        model:    context.request.model,
      } }
    end

    private def self.fail_job(job_id : UUID, error : Exception) : Nil
      job = ::PlaceOS::Model::SignageAIJob.find?(job_id)
      return if job.nil?
      job.state = ::PlaceOS::Model::SignageAIJob::State::Failed
      job.error_kind = kind_of(error)
      job.error_message = message_of(error)
      job.finished_at = Time.utc
      job.save
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))
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
