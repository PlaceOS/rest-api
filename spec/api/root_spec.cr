require "./helper"

module Engine::API
  describe Root do
    with_server do
      # ameba:disable Lint/UselessAssign
      authenticated_user, authorization_header = authentication

      it "responds to health checks" do
        result = curl("GET", "/healthz", headers: authorization_header)
        result.status_code.should eq 200

        result = curl("GET", "/", headers: authorization_header)
        result.status_code.should eq 200
      end

      it "renders version" do
        result = curl("GET", "/version", headers: authorization_header)
        result.status_code.should eq 200
        body = JSON.parse(result.body)
        body["app"].should eq APP_NAME
        body["version"].should eq VERSION
      end
    end
  end
end
