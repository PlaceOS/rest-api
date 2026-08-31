module PlaceOS::Api::ImageGen
  # A per replica cap on concurrent vendor calls.
  #
  # A request reserves one slot per candidate before its job row is written, all
  # or nothing and without blocking. If the reservation fails the caller is told
  # the service is busy (503) and no row is created, so there is never a queued
  # job nobody is working on. Slots are released one per finished vendor call.
  class Slots
    getter capacity : Int32

    def initialize(@capacity : Int32)
      @mutex = Mutex.new
      @in_use = 0
    end

    # Reserve `count` slots, or none at all. Never blocks.
    def try_reserve(count : Int32) : Bool
      return false if count <= 0 || count > @capacity

      @mutex.synchronize do
        return false if @in_use + count > @capacity
        @in_use += count
        true
      end
    end

    # Release one slot. Never drops below zero, so an extra call is harmless.
    def release(count : Int32 = 1) : Nil
      @mutex.synchronize do
        @in_use -= count
        @in_use = 0 if @in_use < 0
      end
    end

    def available : Int32
      @mutex.synchronize { @capacity - @in_use }
    end
  end
end
