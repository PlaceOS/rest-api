require "../helper"

module PlaceOS::Api
  describe Root do
    with_server do
      authenticated_user, authorization_header = authentication
      base = Api::Root::NAMESPACE[0]

      it "responds to health checks" do
        result = curl("GET", base, headers: authorization_header)
        result.status_code.should eq 200
      end

      it "renders version" do
        result = curl("GET", File.join(base, "version"), headers: authorization_header)
        result.status_code.should eq 200
        response = PlaceOS::Model::Version.from_json(result.body)

        response.service.should eq APP_NAME
        response.version.should eq VERSION
        response.build_time.should eq BUILD_TIME
        response.commit.should eq BUILD_COMMIT
      end

      it "gets scope names" do
        result = curl("GET", File.join(base, "scopes"), headers: authorization_header)
        scopes = Array(String).from_json(result.body)
        scopes.size.should eq(Root.scopes.size)
      end

      it "constructs service versions" do
        HttpMocks.service_version

        versions = Root.construct_versions
        versions.size.should eq(Root::SERVICES.size)
        versions.map(&.service.gsub('-', '_')).sort!.should eq Root::SERVICES.sort
      end

      describe "signal" do
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

        context "guests" do
          _, guest_header = authentication(sys_admin: false, support: false, scope: [PlaceOS::Model::UserJWT::Scope::GUEST])

          it "prevented access to non-guest channels " do
            result = curl("POST", File.join(base, "signal?channel=dummy"), body: "hello", headers: guest_header)
            result.status_code.should eq 403
          end

          it "allowed access to guest channels" do
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
end
