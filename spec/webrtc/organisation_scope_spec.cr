require "../helper"

module PlaceOS::Api
  private def self.domain_signaller(user : Model::User, &)
    headers = Spec::Tenancy.headers(user)
    token = headers["Authorization"].split(' ').last
    socket = client.establish_ws("#{WebRTC.base_route}signaller?bearer_token=#{token}", headers: HTTP::Headers{"Host" => headers["Host"]})
    signals = Channel(SessionSignal).new(32)
    socket.on_message do |message|
      signal = SessionSignal.from_json(message)
      signals.send(signal) unless signal.type.ping?
    end
    spawn { socket.run }
    yield socket, signals
  ensure
    socket.try &.close
  end

  private def self.domain_join(socket : HTTP::WebSocket, signals : Channel(SessionSignal), session_id : String, display_id : String) : SessionSignal
    socket.send(SessionSignal.new(id: UUID.random.to_s, type: :join, session_id: session_id, user_id: display_id, to_user: "server", value: nil).to_json)
    loop do
      select
      when signal = signals.receive
        return signal if signal.type.participant_list?
      when timeout(5.seconds)
        raise "timed out waiting for domain participant list"
      end
    end
  end

  describe "domain-scoped WebRTC" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if cleanup = fixture
        Spec::Tenancy.teardown(cleanup)
        fixture = nil
      end
    end

    it "keeps public room lists and details inside the request host's organisation" do
      f = fixture = Spec::Tenancy.build
      [f.acadian.system, f.ucla.system].each do |system|
        system.public = true
        system.save!
      end
      headers = HTTP::Headers{"Host" => f.acadian.authority.domain}
      response = client.get("#{WebRTC.base_route}rooms", headers: headers)
      response.status_code.should eq 200
      Spec::Tenancy.ids(response.body).should eq [f.acadian.system.id]
      client.get("#{WebRTC.base_route}room/#{f.ucla.system.id}", headers: headers).status_code.should eq 404
      client.get("#{WebRTC.base_route}room/#{f.acadian.system.id}", headers: headers).status_code.should eq 200
    end

    it "resolves duplicate room permalinks within the authenticated domain owner" do
      f = fixture = Spec::Tenancy.build
      code = "room-#{random_name}"
      [f.acadian.system, f.ucla.system].each do |system|
        system.update_fields(public: true, code: code)
      end
      [f.acadian, f.ucla].each do |home|
        response = client.get("#{WebRTC.base_route}room/#{code}", headers: HTTP::Headers{"Host" => home.authority.domain})
        response.status_code.should eq 200
        JSON.parse(response.body)["system"]["id"].as_s.should eq home.system.id.as(String)
      end
    end

    it "does not let a foreign or private room with the same code hide an owned public room" do
      f = fixture = Spec::Tenancy.build
      code = "room-#{random_name}"
      f.ucla.system.update_fields(public: true, code: code)
      f.acadian.system.update_fields(public: false, code: code)
      headers = HTTP::Headers{"Host" => f.ucla.authority.domain}
      response = client.get("#{WebRTC.base_route}room/#{code}", headers: headers)
      response.status_code.should eq 200
      JSON.parse(response.body)["system"]["id"].as_s.should eq f.ucla.system.id.as(String)
      client.get("#{WebRTC.base_route}room/#{code}", headers: HTTP::Headers{"Host" => f.acadian.authority.domain}).status_code.should eq 404
    end

    it "isolates the same client session id in two domains" do
      f = fixture = Spec::Tenancy.build
      shared_session = UUID.random.to_s
      domain_signaller(f.acadian.user) do |socket_a, signals_a|
        domain_join(socket_a, signals_a, shared_session, "participant-a")
        domain_signaller(f.ucla.user) do |socket_b, signals_b|
          participants = domain_join(socket_b, signals_b, shared_session, "participant-b")
          Array(String).from_json(participants.value.not_nil!).should eq ["participant-b"]
        end
      end
    end

    it "does not list a different domain's session participants" do
      f = fixture = Spec::Tenancy.build
      session_id = UUID.random.to_s
      domain_signaller(f.ucla.user) do |socket, signals|
        domain_join(socket, signals, session_id, "foreign-participant")
        own = client.get("#{WebRTC.base_route}members/#{session_id}", headers: Spec::Tenancy.headers(f.ucla.user))
        Array(String).from_json(own.body).should eq ["foreign-participant"]
        foreign = client.get("#{WebRTC.base_route}members/#{session_id}", headers: Spec::Tenancy.headers(f.acadian.user))
        foreign.status_code.should eq 200
        Array(String).from_json(foreign.body).should be_empty
      end
    end

    it "does not transfer a participant in another domain" do
      f = fixture = Spec::Tenancy.build
      session_id = UUID.random.to_s
      domain_signaller(f.ucla.user) do |socket, signals|
        domain_join(socket, signals, session_id, "foreign-transfer")
        response = client.post("#{WebRTC.base_route}transfer/foreign-transfer/#{UUID.random}", headers: Spec::Tenancy.headers(f.acadian.user), body: {destination: "private"}.to_json)
        response.status_code.should eq HTTP::Status::PRECONDITION_REQUIRED.code
      end
    end

    it "does not kick a participant in another domain" do
      f = fixture = Spec::Tenancy.build
      session_id = UUID.random.to_s
      domain_signaller(f.ucla.user) do |socket, signals|
        domain_join(socket, signals, session_id, "foreign-kick")
        response = client.post("#{WebRTC.base_route}kick/foreign-kick/#{session_id}", headers: Spec::Tenancy.headers(f.acadian.user), body: {reason: "wrong domain"}.to_json)
        response.status_code.should eq 404
      end
    end
  end
end
