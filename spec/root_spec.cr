require "./helper"

module Engine::API
  describe Root do
    with_server do
      it "responds to health checks" do
        result = curl("GET", "/healthz")
        result.status_code.should eq 200

        result = curl("GET", "/")
        result.status_code.should eq 200
      end

      it "renders version" do
        result = curl("GET", "/version")
        result.status_code.should eq 200
        body = JSON.parse(result.body)
        body["app"].should eq APP_NAME
        body["version"].should eq VERSION
      end
    end
  end
end
