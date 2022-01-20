module PlaceOS::Api
  module Utils::Changefeeds
    def self.await_model_change(model : T, timeout : Time::Span = 20.second, &check : T -> Bool) forall T
      changefeed = model.class.changes(model.id.as(String))
      channel = Channel(T?).new(1)

      begin
        spawn do
          found = changefeed.find do |event|
            check.call(event.value)
          end

          begin
            channel.send(found.try &.value)
          rescue Channel::ClosedError
          end
        end

        select
        when received = channel.receive?
          received
        when timeout(timeout)
          message = "timeout waiting for changes on #{T}"
          Log.info { message }
          raise message
        end
      rescue
        nil
      ensure
        # Terminate the changefeed
        changefeed.stop
        channel.close
      end
    end
  end
end
