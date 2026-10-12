require "placeos-models/signage_ai_job"

module PlaceOS::Api
  # The long poll shared by the signage AI and map AI job routes.
  #
  # The including controller is an `Application` (for `on_primary`).
  module Utils::AIJobs
    MAX_WAIT      = 25
    POLL_INTERVAL = 500.milliseconds

    # Holds until the job's version moves past `since` (the version the caller
    # already has, defaulting to the one just read), the job is final, or
    # `wait` seconds pass. Re-reads go to the primary: a replica may lag the
    # runner's writes.
    def await_job_change(job : ::PlaceOS::Model::SignageAIJob, wait : Int32, since : Int32?) : ::PlaceOS::Model::SignageAIJob
      return job if wait <= 0 || job.final?

      deadline = Time.utc + Math.min(wait, MAX_WAIT).seconds
      known = since || job.version

      while Time.utc < deadline
        sleep POLL_INTERVAL
        fresh = on_primary { ::PlaceOS::Model::SignageAIJob.find?(job.id.as(UUID)) }
        next if fresh.nil?
        job = fresh
        break if job.version > known || job.final?
      end

      job
    end

    # A job of this domain, 404 otherwise so ids from other domains read as unknown.
    def authority_job(id : UUID, authority_id : String) : ::PlaceOS::Model::SignageAIJob
      job = ::PlaceOS::Model::SignageAIJob.find!(id)
      raise Error::NotFound.new("no such job") unless job.authority_id == authority_id
      job
    end
  end
end
