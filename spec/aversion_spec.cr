require "./helper"

module PlaceOS::Api
  describe "version" do
    with_server do
      it "constructs service versions" do
        WebMock.wrap do
          # mock endpoints for service versions
          WebMock
            .stub(:get, "triggers:3000/api/triggers/v2/version").to_return(body: %({"service":"triggers", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
          WebMock
            .stub(:get, "127.0.0.1:3000/api/frontends/v1/version").to_return(body: %({"service":"frontends", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
          WebMock
            .stub(:get, "127.0.0.1:9001/api/core/v1/version").to_return(body: %({"service":"core", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
          WebMock
            .stub(:get, "rubber-soul:3000/api/rubber-soul/v1/version").to_return(body: %({"service":"rubber_soul", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
          WebMock
            .stub(:get, "dispatch:3000/api/server/version").to_return(body: %({"service":"dispatch", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))

          # mock etcd for core service version
          WebMock.stub(:post, "http://etcd:2379/v3beta/kv/range")
            .with(body: "{\"key\":\"c2VydmljZS9jb3JlLw==\",\"range_end\":\"c2VydmljZS9jb3JlMA==\"}", headers: {"Content-Type" => "application/json"})
            .to_return(body: {
              count: "1",
              kvs:   [{
                key:   "c2VydmljZS9jb3JlLw==",
                value: Base64.strict_encode("http://127.0.0.1:9001"),
              }],
            }.to_json)

          WebMock.stub(:post, "http://etcd:2379/v3beta/watch")
            .with(body: "{\"create_request\":{\"key\":\"c2VydmljZS9jb3Jl\",\"range_end\":\"c2VydmljZS9jb3Jm\"}}", headers: {"Content-Type" => "application/json"})
            .to_return(body_io: IO::Stapled.new(*IO.pipe))
          versions = Root.construct_versions
          versions.size.should eq(5)
          versions.map(&.service).sort!.should eq Root::SERVICES.sort
        end
      end
    end
  end
end
