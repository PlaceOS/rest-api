require "../helper"

module PlaceOS::Api
  describe "BuildMonitor" do
    describe "GET /", focus: true do
      it "responds to monitor request" do
        path = "#{BuildMonitor.base_route}monitor"
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
      end
      it "responds to cancel job" do
        path = "#{BuildMonitor.base_route}cancel/uknown_job"
        result = client.get(path, headers: Spec::Authentication.headers)
        result.status_code.should eq 404
      end
    end
  end
end
