require "../helper"

module PlaceOS::Api
  describe Flux do
    path = "#{Flux.base_route.rstrip('/')}/query"
    query = %(from(bucket: "place") |> range(start: -1m))

    it "refuses guest tokens" do
      _, guest_headers = Spec::Authentication.authentication(
        sys_admin: false,
        support: false,
        scope: [Model::UserJWT::Scope::GUEST],
      )
      guest_headers["Content-Type"] = "application/vnd.flux"

      result = client.post(path, headers: guest_headers, body: query)
      result.status_code.should eq 403
    end

    it "lets signed in users through to the proxy" do
      _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
      headers["Content-Type"] = "application/vnd.flux"

      # InfluxDB isn't available in the test environment, so the request
      # fails further on; what matters is that the guest gate didn't refuse it
      result = client.post(path, headers: headers, body: query)
      result.status_code.should_not eq 403
    end
  end
end
