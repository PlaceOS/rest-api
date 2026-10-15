require "../helper"

module PlaceOS::Api
  describe Root do
    describe "GET /" do
      it "responds to health checks" do
        result = client.get(Root.base_route, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
      end
    end

    describe "GET /scopes" do
      it "gets scope names" do
        result = client.get(File.join(Root.base_route, "scopes"), headers: Spec::Authentication.headers)
        scopes = Array(String).from_json(result.body)
        scopes.size.should eq(Root.scopes.size)
      end
    end

    describe "GET /cluster/versions" do
      it "constructs service versions" do
        HttpMocks.service_version

        versions = Root.construct_versions
        versions.size.should eq(Root::SERVICES.size)
        versions.map(&.service.gsub('-', '_')).sort!.should eq Root::SERVICES.sort
      end
    end

    describe "GET /version" do
      it "renders version" do
        result = client.get(File.join(Root.base_route, "version"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        response = PlaceOS::Model::Version.from_json(result.body)

        response.service.should eq APP_NAME
        response.version.should eq VERSION
        response.build_time.should eq BUILD_TIME
        response.commit.should eq BUILD_COMMIT
      end
    end

    describe "GET /platform" do
      it "renders platform information" do
        result = client.get(File.join(Root.base_route, "platform"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        response = PlaceOS::Api::Root::PlatformInfo.from_json(result.body)

        response.version.should eq PLATFORM_VERSION
        response.changelog.should eq PLATFORM_CHANGELOG
      end
    end

    describe "source resync" do
      status_json = ->(state : String, clear : Bool) {
        {state: state, clear: clear, started_at: Time.utc, finished_at: nil, cleared: 0, metadata: 0, error: nil}.to_json
      }

      it "starts a resync with clearing, for a system admin" do
        HttpMocks.reset
        WebMock.stub(:post, /\/api\/source\/v1\/resync\?clear=true$/)
          .to_return(status: 202, body: status_json.call("clearing", true))

        result = client.post(File.join(Root.base_route, "source/resync?clear=true"), headers: Spec::Authentication.headers)
        result.status_code.should eq 202
        status = Root::SourceResyncStatus.from_json(result.body)
        status.state.should eq "clearing"
        status.clear?.should be_true
      end

      it "reports one already running" do
        HttpMocks.reset
        WebMock.stub(:post, /\/api\/source\/v1\/resync\?clear=false$/)
          .to_return(status: 409, body: status_json.call("resyncing", false))

        result = client.post(File.join(Root.base_route, "source/resync"), headers: Spec::Authentication.headers)
        result.status_code.should eq 409
        Root::SourceResyncStatus.from_json(result.body).state.should eq "resyncing"
      end

      it "reports where the last one got to" do
        HttpMocks.reset
        WebMock.stub(:get, /\/api\/source\/v1\/resync$/)
          .to_return(status: 200, body: status_json.call("complete", true))

        result = client.get(File.join(Root.base_route, "source/resync"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        Root::SourceResyncStatus.from_json(result.body).state.should eq "complete"
      end

      it "is for system admins only" do
        HttpMocks.reset
        headers = Spec::Authentication.headers(sys_admin: false, support: true)

        client.post(File.join(Root.base_route, "source/resync"), headers: headers).status_code.should eq 403
        client.get(File.join(Root.base_route, "source/resync"), headers: headers).status_code.should eq 403
      end
    end

    describe "POST /signal" do
      it "writes an arbitrary payload to a redis subscription on scoped channel" do
        user, headers = Spec::Authentication.authenticated
        subscription_channel = "#{user.authority.as(Model::Authority).id}/test"
        channel = Channel(String).new
        subs = PlaceOS::Driver::Subscriptions.new

        _subscription = subs.channel subscription_channel do |_, message|
          channel.send(message)
        end

        params = HTTP::Params{"channel" => "test"}
        result = client.post(File.join(Root.base_route, "signal?#{params}"), body: "hello", headers: headers)
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

      it "writes an arbitrary payload to a redis subscription on un-scoped channel" do
        _, headers = Spec::Authentication.authenticated
        subscription_channel = "test"
        channel = Channel(String).new
        subs = PlaceOS::Driver::Subscriptions.new

        _subscription = subs.channel subscription_channel do |_, message|
          channel.send(message)
        end

        params = HTTP::Params{"channel" => subscription_channel}
        result = client.post(File.join(Root.base_route, "signal?#{params}"), body: "hello", headers: headers)
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
        result = client.post(File.join(Root.base_route, "signal"), body: "hello", headers: Spec::Authentication.headers)
        result.status_code.should eq 422
      end

      context "guest users" do
        it "prevented access to non-guest channels " do
          _, guest_header = Spec::Authentication.authentication(sys_admin: false, support: false, scope: [PlaceOS::Model::UserJWT::Scope::GUEST])

          result = client.post(File.join(Root.base_route, "signal?channel=dummy"), body: "hello", headers: guest_header)
          result.status_code.should eq 403
        end

        it "allowed access to guest channels" do
          guest, guest_header = Spec::Authentication.authentication(sys_admin: false, support: false, scope: [PlaceOS::Model::UserJWT::Scope::GUEST])
          subscription_channel = "/guest/dummy"
          channel = Channel(String).new
          subs = PlaceOS::Driver::Subscriptions.new

          _subscription = subs.channel "#{guest.authority.as(Model::Authority).id}#{subscription_channel}" do |_, message|
            channel.send(message)
          end

          params = HTTP::Params{"channel" => subscription_channel}
          result = client.post(File.join(Root.base_route, "signal?#{params}"), body: "hello", headers: guest_header)
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
