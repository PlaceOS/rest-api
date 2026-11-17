require "./helper"

module PlaceOS::Api
  describe "organisation selection through MCP" do
    router = ActionController::SpecHelper.new
    MCP.mount(router)
    mcp_client = router.hot_topic
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "declares organisation selection on detail tools and resource templates" do
      description = ActionController::MCPServer.generate_description
      _, show = description.tool?("zones_show").not_nil!
      show.params.map(&.name).should contain "organisation_id"
      resources = description.toolboxes.flat_map(&.tools).compact_map(&.resource)
      resources.select(&.includes?("/state")).each do |template|
        template.should contain "organisation_id"
      end
      resources.find!(&.includes?("/logs")).should contain "organisation_id"
    end

    it "passes the selected organisation through tool calls instead of using full partner reach" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.ntt_staff.admin)
      headers["Accept"] = "application/json"
      body = {
        jsonrpc: "2.0",
        id:      1,
        method:  "tools/call",
        params:  {
          name:      "zones_show",
          arguments: {id: f.ntt_staff.org_zone.id, organisation_id: f.acadian.organisation.id.to_s},
        },
      }
      response = mcp_client.post(MCP::PATH, headers: headers, body: body.to_json)
      response.status_code.should eq 200
      result = JSON.parse(response.body)["result"]
      result["isError"].as_bool.should be_true
    end
  end
end
