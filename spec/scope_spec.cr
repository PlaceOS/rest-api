require "./helper"

module PlaceOS::Api
  base = Zones::NAMESPACE[0]

  with_server do
    WebMock.reset
    WebMock.allow_net_connect = true

    describe "default public scope" do
      test_crd(klass: Model::Zone, controller_klass: Zones)
    end

    it ".read scope" do
      _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("zones", PlaceOS::Model::UserJWT::Scope::Access::Read)])
      result = curl(
        method: "GET",
        path: base,
        headers: authorization_header.merge({"Content-Type" => "application/json"}),
      )

      result.success?.should be_true
      zone = Model::Generator.zone.save!
      zone.name = UUID.random.to_s
      path = base
      result = curl(
        method: "POST",
        path: path,
        body: zone.to_json,
        headers: authorization_header.merge({"Content-Type" => "application/json"}),
      )

      result.success?.should be_false
    end

    it ".write scope" do
      _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("zones", PlaceOS::Model::UserJWT::Scope::Access::Write)])
      result = curl(
        method: "GET",
        path: base,
        headers: authorization_header.merge({"Content-Type" => "application/json"}),
      )

      result.success?.should be_false
      zone = Model::Generator.zone.save!
      zone.name = UUID.random.to_s

      path = base
      result = curl(
        method: "POST",
        path: path,
        body: zone.to_json,
        headers: authorization_header.merge({"Content-Type" => "application/json"}),
      )

      result.success?.should be_true
      result.status_code.should eq 201
    end
  end
end
