require "../helper"

module PlaceOS::Api
  describe ShortURL do
    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(klass: Model::Shortener, controller_klass: ShortURL)

      it "redirects" do
        redirect_to = "https://google.com.au/maps"
        uri = Model::Generator.shortener(redirect_to).save!
        id = uri.id.as(String)
        path = File.join(ShortURL.base_route, id, "redirect")
        result = client.get(path: path, headers: HTTP::Headers{
          "Host" => "localhost",
        })

        result.headers["Location"]?.should eq redirect_to
        result.status_code.should eq 303
        uri.destroy
      end
    end

    describe "GET /short_url", tags: "search" do
      it "lists the short URLs for the domain" do
        Model::Shortener.clear
        headers = Spec::Authentication.headers

        url1 = Model::Generator.shortener("https://example.com/#{random_name}").save!
        url2 = Model::Generator.shortener("https://example.com/#{random_name}").save!

        result = client.get(path: ShortURL.base_route, headers: headers)
        result.status_code.should eq 200

        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(url1.id.as(String))
        ids.should contain(url2.id.as(String))
        result.headers["X-Total-Count"].should eq "2"
      end

      it "filters the listing with q" do
        Model::Shortener.clear
        headers = Spec::Authentication.headers

        target = random_name
        match = Model::Generator.shortener("https://example.com/#{target}").save!
        other = Model::Generator.shortener("https://example.com/#{random_name}").save!

        params = HTTP::Params.encode({"q" => target})
        result = client.get(path: "#{ShortURL.base_route}?#{params}", headers: headers)
        result.status_code.should eq 200

        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(match.id.as(String))
        ids.should_not contain(other.id.as(String))
        result.headers["X-Total-Count"].should eq "1"
      end
    end
  end
end
