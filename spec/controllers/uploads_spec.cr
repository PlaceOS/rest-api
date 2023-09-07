require "../helper"

module PlaceOS::Api
  describe Uploads do
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

    it "should handle storage allowed list on get call" do
      s = Model::Generator.storage
      s.ext_filter << "jpg"
      s.save!
      params = HTTP::Params.encode({
        "file_name" => "some_file_name.png",
        "file_size" => "500",
        "file_mime" => "image/png",
      })

      resp = client.get("#{Uploads.base_route}/new?#{params}",
        headers: Spec::Authentication.headers)
      resp.status_code.should eq(400)
      JSON.parse(resp.body).as_h["error"].as_s.should eq("filename extension not allowed")
    end

    it "should handle storage allowed list on post call" do
      s = Model::Generator.storage
      s.ext_filter << ".png"
      s.save!
      params = {
        "file_name" => "some_file_name.jpg",
        "file_size" => "7000000",
        "file_id"   => "some_file_md5_hash",
        "file_mime" => "image/jpeg",
      }

      resp = client.post(Uploads.base_route,
        body: params.to_json,
        headers: Spec::Authentication.headers)
      resp.status_code.should eq(400)
      JSON.parse(resp.body).as_h["error"].as_s.should eq("filename extension not allowed")
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

    it "should handle upload visibility" do
      Model::Storage.clear
      Model::Generator.storage.save!
      params = {
        "file_name"   => "some_file_name.jpg",
        "file_size"   => "500",
        "file_id"     => "some_file_md5_hash",
        "file_mime"   => "image/jpeg",
        "public"      => false,
        "permissions" => "admin",
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
      upload = Model::Upload.find?(info["upload_id"].as_s)
      upload.should_not be_nil
      model = upload.not_nil!
      model.public.should be_false
      model.permissions.should eq Model::Upload::Permissions::Admin

      resp = client.get("#{Uploads.base_route}/#{model.id}/url",
        headers: Spec::Authentication.headers)
      resp.status_code.should eq(303)

      resp = client.get("#{Uploads.base_route}/#{model.id}/url",
        headers: Spec::Authentication.headers(sys_admin: false))
      resp.status_code.should eq(403)
    end
  end
end
