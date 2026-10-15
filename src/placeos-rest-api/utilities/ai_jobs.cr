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

    # What the caller and the domain have left of their allowance, counting the
    # candidates of jobs of `kinds` over the last day and 30 days.
    def remaining_ai_quota(kinds : ::PlaceOS::Model::SignageAIJob::Kind | Array(::PlaceOS::Model::SignageAIJob::Kind), user_limit : Int32, domain_limit : Int32)
      used_today = ::PlaceOS::Model::SignageAIJob.sum_candidates(current_user.id.as(String), 1.day.ago, kinds)
      used_month = ::PlaceOS::Model::SignageAIJob.sum_candidates_for_authority(authority.id.as(String), 30.days.ago, kinds)

      {
        user_remaining_today:   Math.max(0, user_limit - used_today),
        domain_remaining_month: Math.max(0, domain_limit - used_month),
      }
    end

    # Flags the job for its runner to stop, unless it already finished. Only its
    # owner or support may cancel. Returns the job as stored afterwards.
    def request_job_cancel(job : ::PlaceOS::Model::SignageAIJob) : ::PlaceOS::Model::SignageAIJob
      raise Error::Forbidden.new unless job.user_id == current_user.id || user_support?
      return job if job.final?

      job.cancel_requested = true
      job.save
      # in SQL, not read-modify-write: a runner fiber may have moved the
      # version since this row was loaded, and writing a stale value back
      # leaves a long polling client waiting out its whole timeout
      ::PlaceOS::Model::SignageAIJob.bump_version(job.id.as(UUID))
      ::PlaceOS::Model::SignageAIJob.find!(job.id.as(UUID))
    end

    # The domain's jobs of `kinds` from the last 7 days, newest first; only the
    # caller's own unless `mine` is false, which needs support.
    def recent_ai_jobs(kinds : Array(::PlaceOS::Model::SignageAIJob::Kind), mine : Bool)
      labels = kinds.map { |entry| ::PlaceOS::Model::SignageAIJob.kind_label(entry) }
      query = ::PlaceOS::Model::SignageAIJob
        .where(authority_id: authority.id.as(String))
        .where("kind IN (#{labels.map { "?" }.join(", ")})", args: labels.map(&.as(::PgORM::Value)))
      if mine
        query = query.where(user_id: current_user.id.as(String))
      else
        check_support
      end
      query.where("created_at > ?", 7.days.ago).order(created_at: :desc)
    end

    # A job of this domain, 404 otherwise so ids from other domains read as unknown.
    def authority_job(id : UUID, authority_id : String) : ::PlaceOS::Model::SignageAIJob
      job = ::PlaceOS::Model::SignageAIJob.find!(id)
      raise Error::NotFound.new("no such job") unless job.authority_id == authority_id
      job
    end
  end
end
