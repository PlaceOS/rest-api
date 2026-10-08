require "placeos-compiler"

def random_id
  UUID.random.to_s.split('-').first
end

# Waits for core to publish a system's module lookups (`system/<id>` in redis).
#
# The core service running alongside the specs owns these lookups: on each
# ControlSystem change it clears the hash and rebuilds it from the system's
# modules (`<resolved_name>/<index>`), asynchronously and with each changefeed
# event processed concurrently. A lookup seeded by hand is therefore wiped
# whenever core catches up, so instead persist the system once, with its final
# modules, and wait here until core's mapping matches what the spec expects.
def wait_for_module_lookups(system_id : String, expected : Hash(String, String), timeout : Time::Span = 10.seconds) : Nil
  lookup = PlaceOS::Driver::RedisStorage.new(system_id, "system")
  deadline = Time.instant + timeout
  until (current = lookup.to_h) == expected
    raise "timed out waiting for core to map the modules of #{system_id}: expected #{expected}, got #{current}" if Time.instant > deadline
    sleep 10.milliseconds
  end
end
