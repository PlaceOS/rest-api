require "./helper"

module Engine::API
  describe Zones do
    # Generate some zone data
    with_server do
      it "should respond to health checks" do
        result = curl("GET", "/healthz")
        result.status.should eq 200
      end

      it "renders version" do
        result = curl("GET", "/version")
        result.status.should eq 200
        pp! result.body
      end
    end
  end
end
