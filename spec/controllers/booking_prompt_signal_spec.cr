require "../helper"

module PlaceOS::Api
  private def self.prompt_signal_headers(authority : Model::Authority, roles : Array(String)) : HTTP::Headers
    token = Model::UserJWT.new(
      iss: Model::UserJWT::ISSUER, iat: 5.minutes.ago, exp: 1.hour.from_now,
      domain: authority.domain, id: "host@external.test",
      user: Model::UserJWT::Metadata.new(name: "Booking host", email: "host@external.test", permissions: Model::UserJWT::Permissions::User, roles: roles),
      scope: [Model::UserJWT::Scope::GUEST],
    )
    HTTP::Headers{"Host" => authority.domain, "Content-Type" => "application/json", "Authorization" => "Bearer #{token.encode}"}
  end

  describe "booking prompt signal compatibility" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    subscriptions = nil.as(Driver::Subscriptions?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      subscriptions.try(&.terminate)
      subscriptions = nil
      Utils::Tenancy.enforce = false
      if cleanup = fixture
        Spec::Tenancy.teardown(cleanup)
        fixture = nil
      end
    end

    it "delivers the unchanged booked-room guest path and payload to the legacy driver channel" do
      f = fixture = Spec::Tenancy.build
      event = "event-#{random_name}"
      path = "#{f.acadian.system.id}/guest/bookings/prompted"
      messages = Channel(String).new(8)
      subscriptions = subs = Driver::Subscriptions.new
      subs.channel(path) { |_, body| messages.send(body) }
      body = {id: event, check_in: true}.to_json
      params = HTTP::Params{"channel" => path}
      response = client.post("#{Root.base_route}signal?#{params}", headers: prompt_signal_headers(f.acadian.authority, [event, f.acadian.system.id.as(String)]), body: body)
      response.status_code.should eq 200
      select
      when received = messages.receive
        received.should eq body
      when timeout(2.seconds)
        fail "authorised unchanged booking prompt did not reach the driver"
      end
    end

    it "requires the invited system capability even when the guest knows an owned room id" do
      f = fixture = Spec::Tenancy.build
      event = "event-#{random_name}"
      path = "#{f.acadian.system.id}/guest/bookings/prompted"
      messages = Channel(String).new(8)
      subscriptions = subs = Driver::Subscriptions.new
      subs.channel(path) { |_, body| messages.send(body) }
      params = HTTP::Params{"channel" => path}
      response = client.post("#{Root.base_route}signal?#{params}", headers: prompt_signal_headers(f.acadian.authority, [event]), body: {id: event, check_in: true}.to_json)
      response.status_code.should eq 403
      select
      when messages.receive
        fail "an uninvited guest published a booking prompt"
      when timeout(100.milliseconds)
      end
    end

    it "requires the prompted booking id to match the guest capability" do
      f = fixture = Spec::Tenancy.build
      path = "#{f.acadian.system.id}/guest/bookings/prompted"
      params = HTTP::Params{"channel" => path}
      headers = prompt_signal_headers(f.acadian.authority, ["invited-event", f.acadian.system.id.as(String)])
      client.post("#{Root.base_route}signal?#{params}", headers: headers, body: {id: "another-event", check_in: false}.to_json).status_code.should eq 403
    end

    it "does not accept foreign room capabilities on the authenticated guest domain" do
      f = fixture = Spec::Tenancy.build
      path = "#{f.ucla.system.id}/guest/bookings/prompted"
      messages = Channel(String).new(8)
      subscriptions = subs = Driver::Subscriptions.new
      subs.channel(path) { |_, body| messages.send(body) }
      headers = prompt_signal_headers(f.acadian.authority, ["invited-event", f.ucla.system.id.as(String)])
      params = HTTP::Params{"channel" => path}
      client.post("#{Root.base_route}signal?#{params}", headers: headers, body: {id: "invited-event", check_in: true}.to_json).status_code.should eq 404
      select
      when messages.receive
        fail "a foreign room received a prompt from another domain"
      when timeout(100.milliseconds)
      end
    end

    it "does not publish arbitrary global channels while retaining domain-scoped signalling" do
      f = fixture = Spec::Tenancy.build
      path = "arbitrary-#{random_name}/guest/prompted"
      messages = Channel(Tuple(String, String)).new(8)
      subscriptions = subs = Driver::Subscriptions.new
      subs.channel(path) { |_, body| messages.send({"global", body}) }
      subs.channel("#{f.acadian.authority.id}/#{path}") { |_, body| messages.send({"scoped", body}) }
      params = HTTP::Params{"channel" => path}
      client.post("#{Root.base_route}signal?#{params}", headers: Spec::Tenancy.headers(f.acadian.admin), body: "unchanged").status_code.should eq 200
      select
      when received = messages.receive
        received.should eq({"scoped", "unchanged"})
      when timeout(2.seconds)
        fail "domain-scoped signal was not delivered"
      end
      select
      when received = messages.receive
        received[0].should_not eq "global"
      when timeout(100.milliseconds)
      end
    end
  end
end
