require "../helper"

module PlaceOS::Api
  describe WebRTC do
    describe "GET /api/engine/v2/webrtc/rooms", tags: "search" do
      # the route is unauthenticated: the domain's authority is resolved from
      # the Host header, so requests carry no Authorization header at all
      rooms_route = "/api/engine/v2/webrtc/rooms"
      no_auth = HTTP::Headers{"Host" => "localhost"}

      it "lists only public systems, without authentication" do
        # ensure the localhost authority exists (route resolves it from Host)
        Spec::Authentication.headers

        public_sys = Model::Generator.control_system
        public_sys.public = true
        public_sys.save!

        private_sys = Model::Generator.control_system
        private_sys.public = false
        private_sys.save!

        result = client.get(path: rooms_route, headers: no_auth)
        result.status_code.should eq 200

        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(public_sys.id.as(String))
        ids.should_not contain(private_sys.id.as(String))
        result.headers["X-Total-Count"].to_i.should be >= 1
      end

      it "filters rooms by name with q" do
        Spec::Authentication.headers

        target = random_name
        match = Model::Generator.control_system
        match.name = target
        match.public = true
        match.save!

        other = Model::Generator.control_system
        other.public = true
        other.save!

        params = HTTP::Params.encode({"q" => target})
        result = client.get(path: "#{rooms_route}?#{params}", headers: no_auth)
        result.status_code.should eq 200

        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(match.id.as(String))
        ids.should_not contain(other.id.as(String))
      end

      it "filters rooms to the authority's webrtc_zone" do
        Spec::Authentication.headers
        authority = Model::Authority.find_by_domain("localhost").not_nil!

        zone = Model::Generator.zone.save!
        zone_id = zone.id.as(String)

        in_zone = Model::Generator.control_system
        in_zone.public = true
        in_zone.zones = [zone_id]
        in_zone.save!

        out_of_zone = Model::Generator.control_system
        out_of_zone.public = true
        out_of_zone.save!

        begin
          authority.internals_will_change!
          authority.internals["webrtc_zone"] = JSON::Any.new(zone_id)
          authority.save!

          result = client.get(path: rooms_route, headers: no_auth)
          result.status_code.should eq 200

          ids = Array(Hash(String, JSON::Any))
            .from_json(result.body)
            .map(&.["id"].as_s)
          ids.should contain(in_zone.id.as(String))
          ids.should_not contain(out_of_zone.id.as(String))
        ensure
          authority.internals_will_change!
          authority.internals.delete("webrtc_zone")
          authority.save!
        end
      end
    end
  end
end
