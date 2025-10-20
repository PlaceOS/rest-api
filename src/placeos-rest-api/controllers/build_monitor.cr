require "placeos-core-client"
require "placeos-driver/proxy/system"

require "./application"

module PlaceOS::Api
  class BuildMonitor < Application
    base "/api/engine/v2/build/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:monitor]
    before_action :can_write, only: [:cancel]

    before_action :check_admin, only: [:cancel]

    ###############################################################################################

    @[AC::Route::GET("/monitor")]
    def monitor(
      @[AC::Param::Info(name: "state", description: "state of job to return. One of [pending,running,cancelled error,done]. Defaults to 'pending'", example: "pending")]
      state : PlaceOS::Core::Client::State = PlaceOS::Core::Client::State::Pending,
    ) : Array(TaskStatus) | String
      code, result = self.class.monitor_jobs(state, request_id)
      if code < 500
        render status: code, json: Array(TaskStatus).from_json(result)
      else
        render status: code, text: result
      end
    end

    @[AC::Route::DELETE("/cancel/:job")]
    def cancel(
      @[AC::Param::Info(name: "job", description: "ID of previously submitted compilation job")]
      job : String,
    ) : CancelStatus
      code, result = self.class.cancel_job(job, request_id)
      render status: code, json: CancelStatus.from_json(result)
    end

    def self.monitor_jobs(state : PlaceOS::Core::Client::State, request_id : String)
      details = RemoteDriver.default_discovery.node_hash

      promises = details.map do |core_id, uri|
        Promise.defer {
          core_for(uri, request_id) do |core_client|
            core_client.monitor_jobs(state)
          end
        }.catch { |error|
          Log.error(exception: error) { {
            message:  "failure to request a build service job status",
            core_uri: uri.to_s,
            core_id:  core_id,
            state:    state.to_s,
          } }
          {500, error.message || "failure to request a build service job status"}
        }
      end

      Promise.race(promises).get
    end

    def self.cancel_job(job : String, request_id : String)
      details = RemoteDriver.default_discovery.node_hash

      promises = details.map do |core_id, uri|
        Promise.defer {
          core_for(uri, request_id) do |core_client|
            core_client.cancel_job(job)
          end
        }.catch { |error|
          Log.error(exception: error) { {
            message:  "failure to request a cancellation of build service job",
            core_uri: uri.to_s,
            core_id:  core_id,
            job:      job,
          } }
          {500, {status: "error", message: error.message || "failure to request a cancellation of build service job"}.to_json}
        }
      end

      Promise.race(promises).get
    end

    def self.core_for(uri, request_id : String? = nil, & : Core::Client -> V) forall V
      Core::Client.client(uri: uri, request_id: request_id) do |client|
        yield client
      end
    end

    enum State
      Pending
      Running
      Cancelled
      Error
      Done

      def to_s(io : IO) : Nil
        io << (member_name || value.to_s).downcase
      end

      def to_s : String
        String.build { |io| to_s(io) }
      end
    end

    record TaskStatus, state : State, id : String, message : String,
      driver : String, repo : String, branch : String, commit : String, timestamp : Time do
      include JSON::Serializable
    end

    record CancelStatus, status : String, message : String do
      include JSON::Serializable
    end
  end
end
