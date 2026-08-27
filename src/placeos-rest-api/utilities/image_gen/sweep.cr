require "placeos-driver/storage"
require "placeos-models/playlist/item"
require "placeos-models/signage_ai_job"
require "placeos-models/upload"

module PlaceOS::Api::ImageGen
  # Housekeeping.
  #
  # Candidates nobody kept, and reference images uploaded for one request, are
  # removed after the retention window. A candidate that was kept is left alone:
  # it is the media item's file, and its tag is the provenance record. Jobs left
  # running by a replica that went away are marked failed so a client stops
  # waiting on them.
  #
  # One replica does the work at a time, held by a Redis key. Nothing slow
  # happens inside the `with_redis` block: it holds a single shared client
  # behind a mutex.
  module Sweep
    LOCK_KEY = "placeos/signage_ai/sweep"

    def self.start : Tasker::Repeat(Nil)?
      return nil if SIGNAGE_AI_DISABLED

      period = SIGNAGE_AI_RETENTION / 8
      period = 15.minutes if period < 15.minutes

      Log.info { {message: "signage AI sweep scheduled", every: period.to_s, retention: SIGNAGE_AI_RETENTION.to_s} }

      Tasker.instance.every(period) do
        begin
          run
        rescue ex
          Log.error(exception: ex) { "signage AI sweep failed" }
        end
        nil
      end
    end

    def self.run : Nil
      ttl = 10.minutes.total_seconds.to_i
      # SET NX EX in one call: taken and released outside any long work
      taken = ::PlaceOS::Driver::RedisStorage.with_redis do |redis|
        redis.set(LOCK_KEY, Time.utc.to_unix.to_s, nx: true, ex: ttl)
      end
      return unless taken

      begin
        expire_stale_jobs
        remove_unclaimed_uploads
      ensure
        ::PlaceOS::Driver::RedisStorage.with_redis(&.del(LOCK_KEY))
      end
    end

    # a job still running long after the replica that owned it went away
    private def self.expire_stale_jobs : Nil
      cutoff = Time.utc - SIGNAGE_AI_JOB_STALE
      ::PlaceOS::Model::SignageAIJob.stale(cutoff).each do |job|
        job.state = ::PlaceOS::Model::SignageAIJob::State::Failed
        job.error_kind = "timeout"
        job.error_message = "the job did not finish"
        job.finished_at = Time.utc
        job.version = job.version + 1
        job.save
        Log.warn { {message: "signage AI job expired", job: job.id.to_s} }
      end
    end

    private def self.remove_unclaimed_uploads : Nil
      cutoff = Time.utc - SIGNAGE_AI_RETENTION

      # bind each tag individually: an array cannot go in as one parameter
      tags = [Store::CANDIDATE_TAG, Store::REFERENCE_TAG]
      placeholders = Array.new(tags.size, "?").join(", ")
      args = ([cutoff] of ::PgORM::Value) + tags.map(&.as(::PgORM::Value))

      uploads = ::PlaceOS::Model::Upload
        .where("created_at < ? AND tags && ARRAY[#{placeholders}]::text[]", args: args)
        .to_a

      return if uploads.empty?

      uploads.each do |upload|
        id = upload.id.as(String)
        next if referenced?(id)

        begin
          if (storage = upload.storage)
            Store.signer_for(storage).delete_file(storage.bucket_name, upload.object_key, upload.resumable_id)
          end
        rescue ex
          Log.warn(exception: ex) { {message: "could not remove a swept object", upload: id} }
        end

        upload.destroy
      end
    end

    # kept if a media item points at it, either as the artwork or its thumbnail
    private def self.referenced?(upload_id : String) : Bool
      ::PlaceOS::Model::Playlist::Item
        .where("media_id = ? OR thumbnail_id = ?", upload_id, upload_id)
        .count > 0
    end
  end
end
