require "../helper"

module PlaceOS::Api
  describe Cluster do
    it "should return a load status when include_status = false" do
      path = Cluster.base_route
      result = client.get(
        path: path,
        headers: Spec::Authentication.headers,
      )

      result.success?.should be_true
      ns = Array(Cluster::NodeStatus).from_json(result.body)
      ns.all? { |rec| !rec.load.nil? }.should be_true
    end
  end
end
