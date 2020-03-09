require "./helper"

module PlaceOS::Api
  describe Root do
    with_server do
      _, authorization_header = authentication
      base = Api::Root::NAMESPACE[0]

      it "responds to health checks" do
        result = curl("GET", File.join(base, "healthz"), headers: authorization_header)
        result.status_code.should eq 200

        result = curl("GET", base, headers: authorization_header)
        result.status_code.should eq 200
      end

      it "renders version" do
        result = curl("GET", File.join(base, "version"), headers: authorization_header)
        result.status_code.should eq 200
        body = JSON.parse(result.body)
        body["app"].should eq APP_NAME
        body["version"].should eq VERSION
      end
    end
  end
end
