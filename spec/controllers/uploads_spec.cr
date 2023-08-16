require "../helper"

module PlaceOS::Api
  describe Uploads, focus: true do
    # Spec.test_404(Uploads.base_route, model_name: Model::Upload.table_name, headers: Spec::Authentication.headers)

    it "new should return the Storage Provider" do
      Model::Generator.storage.save!
      params = HTTP::Params.encode({
        "file_name" => "some_file_name.jpg",
        "file_size" => "500",
        "file_mime" => "image/jpeg",
      })

      resp = client.get("#{Uploads.base_route}/new?#{params}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)
      JSON.parse(resp.body).as_h["residence"].should eq("AmazonS3")
    end

    it "post should return the pre-signed signature" do
      Model::Storage.clear
      Model::Generator.storage.save!
      params = {
        "file_name" => "some_file_name.jpg",
        "file_size" => "500",
        "file_id"   => "some_file_md5_hash",
        "file_mime" => "image/jpeg",
      }

      resp = client.post(Uploads.base_route,
        body: params.to_json,
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)
      info = JSON.parse(resp.body).as_h
      info["type"].should eq("direct_upload")
      sig = info["signature"].as_h
      sig["verb"].as_s.should eq("PUT")
      sig["url"].as_s.should_not be_nil
      Model::Upload.find?(info["upload_id"].as_s).should_not be_nil
    end

    it "post should return the pre-signed signature for multi-part" do
      Model::Storage.clear
      Model::Generator.storage.save!
      params = {
        "file_name" => "some_file_name.jpg",
        "file_size" => "7000000",
        "file_id"   => "some_file_md5_hash",
        "file_mime" => "image/jpeg",
      }

      resp = client.post(Uploads.base_route,
        body: params.to_json,
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)

      info = JSON.parse(resp.body).as_h
      info["type"].should eq("chunked_upload")
      sig = info["signature"].as_h
      sig["verb"].as_s.should eq("POST")
      sig["url"].as_s.should_not be_nil
      Model::Upload.find?(info["upload_id"].as_s).should_not be_nil
    end
  end
end
