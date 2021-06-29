require "./helper"
require "webmock"

Spec.before_each &->WebMock.reset

module PlaceOS::Api
  describe Root do
    with_server do
      _, authorization_header = authentication
      base = Api::Root::NAMESPACE[0]

      it "responds to health checks" do
        WebMock.allow_net_connect = true
        result = curl("GET", base, headers: authorization_header)
        result.status_code.should eq 200
      end

      it "renders version" do
        WebMock.allow_net_connect = true
        result = curl("GET", File.join(base, "version"), headers: authorization_header)
        result.status_code.should eq 200
        response = PlaceOS::Model::Version.from_json(result.body)

        response.service.should eq APP_NAME
        response.version.should eq VERSION
        response.build_time.should eq BUILD_TIME
        response.commit.should eq BUILD_COMMIT
      end

      it "constructs version" do
        WebMock
          .stub(:get, "triggers:3000/api/triggers/v2/version").to_return(body: %({"service":"triggers", "commit":"DEV", "version":"1.27.3", "build_time":"Tue Jun 29 04:19:47 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "localhost:3000/api/frontends/v1/version").to_return(body: %({"service":"frontends", "commit":"DEV", "version":"1.27.3", "build_time":"Tue Jun 29 04:19:47 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "localhost:3000/api/core/v1/version").to_return(body: %({"service":"core", "commit":"DEV", "version":"1.27.3", "build_time":"Tue Jun 29 04:19:47 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "localhost:3000/api/rubber-soul/v1/version").to_return(body: %({"service":"rubber-soul", "commit":"DEV", "version":"1.27.3", "build_time":"Tue Jun 29 04:19:47 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "localhost:3000/api/server/version").to_return(body: %({"service":"dispatch", "commit":"DEV", "version":"1.27.3", "build_time":"Tue Jun 29 04:19:47 UTC 2021", "platform_version":"DEV"}))
        puts Root.construct_versions
      end

      describe "signal" do
        WebMock.allow_net_connect = true
        it "writes an arbitrary payload to a redis subscription" do
          subscription_channel = "test"
          channel = Channel(String).new
          subs = PlaceOS::Driver::Subscriptions.new

          _subscription = subs.channel subscription_channel do |_, message|
            channel.send(message)
          end

          params = HTTP::Params{"channel" => subscription_channel}
          result = curl("POST", File.join(base, "signal?#{params}"), body: "hello", headers: authorization_header)
          result.status_code.should eq 200

          begin
            select
            when message = channel.receive
              message.should eq "hello"
            when timeout 2.seconds
              raise "timeout"
            end
          ensure
            subs.terminate
          end
        end

        it "validates presence of `channel` param" do
          result = curl("POST", File.join(base, "signal"), body: "hello", headers: authorization_header)
          result.status_code.should eq 400
        end

        it "prevents access to non-guest channels for guests" do
          _, guest_header = authentication(["guest"])
          result = curl("POST", File.join(base, "signal?channel=dummy"), body: "hello", headers: guest_header)
          result.status_code.should eq 403
        end

        it "allows access to guest channels for guests" do
          _, guest_header = authentication(["guest"])

          subscription_channel = "/guest/dummy"
          channel = Channel(String).new
          subs = PlaceOS::Driver::Subscriptions.new

          _subscription = subs.channel subscription_channel do |_, message|
            channel.send(message)
          end

          params = HTTP::Params{"channel" => subscription_channel}
          result = curl("POST", File.join(base, "signal?#{params}"), body: "hello", headers: guest_header)
          result.status_code.should eq 200

          begin
            select
            when message = channel.receive
              message.should eq "hello"
            when timeout 2.seconds
              raise "timeout"
            end
          ensure
            subs.terminate
          end
        end
      end
    end
  end
end
