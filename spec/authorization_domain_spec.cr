require "./helper"

module PlaceOS::Api
  describe "authorization domain matching" do
    current_path = File.join(Users.base_route, "/current")
    other_domain = "tenant-b.example"

    before_each do
      Model::Authority.find_by_domain(other_domain) || Model::Generator.authority(other_domain).save!
    end

    it "rejects a JWT issued for another authority's domain" do
      _, headers = Spec::Authentication.authentication
      client.get(current_path, headers: headers).status_code.should eq 200

      headers["Host"] = other_domain
      client.get(current_path, headers: headers).status_code.should eq 401
    end

    it "rejects an API key belonging to another authority's domain" do
      _, headers = Spec::Authentication.x_api_authentication
      client.get(current_path, headers: headers).status_code.should eq 200

      headers["Host"] = other_domain
      client.get(current_path, headers: headers).status_code.should eq 401
    end
  end
end
