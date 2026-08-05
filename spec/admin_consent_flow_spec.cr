require "./helper"

module PlaceOS::Api
  describe AdminConsentFlow do
    it "round-trips flow state through redis" do
      flow = AdminConsentFlow.new(UUID.v4.to_s, "authority-test", "/backoffice/#/domains/authority-test/authentication")
      flow.save

      loaded = AdminConsentFlow.load(flow.id).not_nil!
      loaded.state.should eq "running"
      loaded.steps.size.should eq 5
      loaded.steps.all? { |step| step.state == "pending" }.should be_true
      loaded.redirect.should eq "/backoffice/#/domains/authority-test/authentication"

      flow.start_step("auth_app")
      loaded = AdminConsentFlow.load(flow.id).not_nil!
      loaded.steps.find! { |step| step.key == "auth_app" }.state.should eq "running"

      flow.detail("Waiting for Microsoft to replicate (attempt 2)")
      AdminConsentFlow.load(flow.id).not_nil!.detail.should eq "Waiting for Microsoft to replicate (attempt 2)"

      flow.complete!
      loaded = AdminConsentFlow.load(flow.id).not_nil!
      loaded.state.should eq "complete"
      loaded.steps.all? { |step| step.state == "done" }.should be_true
      loaded.detail.should be_nil
    end

    it "advances earlier steps to done when a later step starts" do
      flow = AdminConsentFlow.new(UUID.v4.to_s, "authority-test", "/x")
      flow.start_step("visualiser")
      flow.start_step("outlook")
      loaded = AdminConsentFlow.load(flow.id).not_nil!
      loaded.steps.find! { |step| step.key == "visualiser" }.state.should eq "done"
      loaded.steps.find! { |step| step.key == "outlook" }.state.should eq "running"
      loaded.steps.find! { |step| step.key == "saving" }.state.should eq "pending"
    end

    it "marks the running step failed and records the error" do
      flow = AdminConsentFlow.new(UUID.v4.to_s, "authority-test", "/x")
      flow.start_step("visualiser")
      flow.fail!("boom")
      loaded = AdminConsentFlow.load(flow.id).not_nil!
      loaded.state.should eq "failed"
      loaded.error.should eq "boom"
      loaded.steps.find! { |step| step.key == "visualiser" }.state.should eq "failed"
    end

    it "returns nil for unknown flows" do
      AdminConsentFlow.load("unknown-#{UUID.v4}").should be_nil
    end
  end
end
