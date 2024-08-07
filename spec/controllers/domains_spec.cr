require "../helper"

module PlaceOS::Api
  describe Domains do
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
