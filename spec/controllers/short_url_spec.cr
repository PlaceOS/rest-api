require "../helper"

module PlaceOS::Api
  describe ShortURL do
    describe "CRUD operations", tags: "crud" do
      Spec.test_crd(klass: Model::Shortener, controller_klass: ShortURL)

      it "redirects" do
        redirect_to = "https://google.com.au/maps"
        uri = Model::Generator.shortener(redirect_to).save!
        id = uri.id.as(String)
        path = File.join(ShortURL.base_route, id)
        result = client.get(path: path)

        result.success?.should be_true
        result.headers["Location"]?.should eq redirect_to
        uri.destroy
      end
    end
  end
end
