require "../helper"

module PlaceOS::Api
  describe Domains do
    describe "index", tags: "search" do
      it "lists domains with pagination headers" do
        authority_a = Model::Generator.authority("a-#{random_name}.example.com").save!
        authority_b = Model::Generator.authority("b-#{random_name}.example.com").save!

        result = client.get(Domains.base_route, headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        ids = Array(Hash(String, JSON::Any)).from_json(result.body).map(&.["id"].as_s)
        ids.should contain(authority_a.id)
        ids.should contain(authority_b.id)

        result.headers["X-Total-Count"].to_i64.should eq Model::Authority.count
      end

      it "filters domains via q" do
        target = Model::Generator.authority("q-#{random_name}.example.com")
        target.name = random_name
        target.save!
        Model::Generator.authority("other-#{random_name}.example.com").save!

        params = HTTP::Params.encode({"q" => target.name})
        result = client.get("#{Domains.base_route}?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        domains = Array(Hash(String, JSON::Any)).from_json(result.body)
        domains.size.should eq 1
        domains.first["id"].as_s.should eq target.id
        result.headers["X-Total-Count"].should eq "1"
      end
    end

    it "Lookup domain via user email" do
      authority = Model::Generator.authority("https://www.dev-placeos.com", ["placeos.com", "dev-placeos.com"]).save!
      email = URI.encode_www_form("test@placeos.com")
      path = "#{Domains.base_route}lookup/#{email}"
      result = client.get(path)
      result.status_code.should eq(200)
      result.body.strip('"').should eq(authority.domain)
    end
  end
end
