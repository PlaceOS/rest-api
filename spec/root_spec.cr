require "./helper"

module PlaceOS::Api
  describe Root do
    with_server do
      _, authorization_header = authentication
      base = Api::Root::NAMESPACE[0]

      it "responds to health checks" do
        result = curl("GET", base, headers: authorization_header)
        result.status_code.should eq 200
      end

      it "renders version" do
        result = curl("GET", File.join(base, "version"), headers: authorization_header)
        result.status_code.should eq 200

        response = NamedTuple(
          app: String,
          version: String,
          build_time: String,
          commit: String).from_json(result.body)

        response[:app].should eq APP_NAME
        response[:version].should eq VERSION
        response[:build_time].should eq BUILD_TIME
        response[:commit].should eq BUILD_COMMIT
      end
    end
  end
end
