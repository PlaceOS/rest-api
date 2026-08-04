require "json"

module PlaceOS::Api
  # Progress state for an in-flight Azure admin-consent flow.
  #
  # The consent callback spawns the Microsoft Graph work into a fiber and
  # responds immediately with a progress page; state lives in redis (with a
  # TTL) so any replica can answer the page's polling.
  class AdminConsentFlow
    include JSON::Serializable

    # generous - a flow riding out replication retries can run for minutes
    TTL_SECONDS = 900

    STEP_DEFINITIONS = [
      {"visualiser", "Register the Bookings Visualiser application"},
      {"auth_app", "Register the User Authentication application"},
      {"outlook", "Configure the Outlook add-in"},
      {"saving", "Save the authentication configuration"},
    ]

    class Step
      include JSON::Serializable

      property key : String
      property label : String
      property state : String # pending | running | done | failed

      def initialize(@key, @label, @state = "pending")
      end
    end

    property id : String
    property state : String # running | complete | failed
    property steps : Array(Step)
    property detail : String?
    property error : String?
    property redirect : String
    property authority_id : String
    property updated_at : Int64

    def initialize(@id, @authority_id, @redirect)
      @state = "running"
      @steps = STEP_DEFINITIONS.map { |(key, label)| Step.new(key, label) }
      @updated_at = Time.utc.to_unix
    end

    def start_step(key : String) : Nil
      @steps.each do |step|
        case step.key
        when key then step.state = "running"
        else          step.state = "done" if step.state == "running"
        end
      end
      @detail = nil
      save
    end

    def detail(message : String) : Nil
      @detail = message
      save
    end

    def complete! : Nil
      @steps.each { |step| step.state = "done" }
      @state = "complete"
      @detail = nil
      save
    end

    def fail!(message : String) : Nil
      @steps.each { |step| step.state = "failed" if step.state == "running" }
      @state = "failed"
      @error = message
      @detail = nil
      save
    end

    def save : Nil
      @updated_at = Time.utc.to_unix
      payload = to_json
      ::PlaceOS::Driver::RedisStorage.with_redis(&.set(self.class.redis_key(id), payload, ex: TTL_SECONDS))
    end

    def self.load(id : String) : AdminConsentFlow?
      payload = ::PlaceOS::Driver::RedisStorage.with_redis(&.get(redis_key(id)))
      payload ? from_json(payload) : nil
    end

    def self.redis_key(id : String) : String
      "placeos:admin_consent:flow:#{id}"
    end
  end
end
