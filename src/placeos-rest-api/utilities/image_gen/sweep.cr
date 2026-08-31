require "placeos-driver/storage"
require "placeos-models/playlist/item"
require "placeos-models/metadata"
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
        job.save
        ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))
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

      # read once, not once per upload: this is every tenant's brand kit
      logos = brand_logo_ids

      uploads.each do |upload|
        id = upload.id.as(String)
        next if referenced?(id, logos)

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

    # kept if a media item points at it, either as the artwork or its thumbnail,
    # or if a brand kit does
    private def self.referenced?(upload_id : String, logos : Set(String)?) : Bool
      # nil means the brand kits could not be read, and a read that failed is
      # not permission to delete
      return true if logos.nil?
      return true if logos.includes?(upload_id)

      ::PlaceOS::Model::Playlist::Item
        .where("media_id = ? OR thumbnail_id = ?", upload_id, upload_id)
        .count > 0
    end

    # Every logo any brand kit points at.
    #
    # A logo is uploaded through the same untagged path a throwaway reference
    # uses, and is pointed at only from zone metadata, which nothing else here
    # looks at. Without this a logo that had been attached to a request as a
    # reference would be swept and the brand kit left pointing at a dead file.
    #
    # nil rather than an empty set when the read fails, so a database fault
    # cannot read as "no brand kit has any logos".
    private def self.brand_logo_ids : Set(String)?
      ids = Set(String).new
      ::PlaceOS::Model::Metadata.where(name: "signage_ai").each do |metadata|
        details = metadata.details.as_h?
        next unless details
        {"logo_upload_id", "logo_dark_upload_id"}.each do |key|
          if (id = details[key]?.try(&.as_s?))
            ids << id
          end
        end
      end
      ids
    rescue ex
      Log.warn(exception: ex) { "could not read brand kits, keeping every upload this pass" }
      nil
    end
  end
end
