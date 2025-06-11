require "../helper"

module PlaceOS::Api
  describe Uploads do
    ::Spec.before_each do
      Model::Storage.clear
    end

    it "should support pagination on list of uploads request" do
      s = Model::Generator.storage.save!

      Model::Generator.upload(file_name: "some_file", storage_id: s.id).save!
      Model::Generator.upload(file_name: "some_file2", storage_id: s.id).save!
      Model::Generator.upload(file_name: "my_file", storage_id: s.id).save!
      Model::Generator.upload(file_name: "my_file2", storage_id: s.id).save!

      params = HTTP::Params.encode({
        "limit" => "1",
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "4"
      result.headers["Content-Range"].should eq "items 0-0/4"
      result.headers["Link"]?.should_not be_nil
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(1)

      params = HTTP::Params.encode({
        "file_search" => "my_file",
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "2"
      result.headers["Content-Range"].should eq "items 0-1/2"
      result.headers["Link"]?.should be_nil
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(2)
    end

    it "should support tag filtering on list of uploads" do
      s = Model::Generator.storage.save!

      Model::Generator.upload(file_name: "some_file", storage_id: s.id).save!
      Model::Generator.upload(file_name: "some_file2", storage_id: s.id).save!
      tagged = Model::Generator.upload(file_name: "my_file", storage_id: s.id)
      tagged.tags = ["staff", "email1@domain.com"]
      tagged.save!
      tagged = Model::Generator.upload(file_name: "my_file2", storage_id: s.id)
      tagged.tags = ["staff", "email2@domain.com"]
      tagged.save!

      params = HTTP::Params.encode({
        "tags" => "staff",
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "2"
      result.headers["Content-Range"].should eq "items 0-1/2"
      result.headers["Link"]?.should be_nil
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(2)

      params = HTTP::Params.encode({
        "tags" => "staff,email1@domain.com",
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "1"
      result.headers["Content-Range"].should eq "items 0-0/1"
      result.headers["Link"]?.should be_nil
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(1)

      params = HTTP::Params.encode({
        "file_search" => "my_file",
        "tags"        => "staff",
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "2"
      result.headers["Content-Range"].should eq "items 0-1/2"
      result.headers["Link"]?.should be_nil
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(2)
    end

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
      JSON.parse(resp.body).as_h["error"].as_s.should eq("File extension not allowed")
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
      JSON.parse(resp.body).as_h["error"].as_s.should eq("File extension not allowed")
    end

    it "post should return the pre-signed signature" do
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

    it "should properly handle azure storage for direct uploads" do
      storage = Model::Generator.storage(type: PlaceOS::Model::Storage::Type::Azure)
      storage.access_key = "myteststorage"
      storage.access_secret = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
      storage.save!
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
    end

    it "should properly handle azure storage for chunked uploads" do
      storage = Model::Generator.storage(type: PlaceOS::Model::Storage::Type::Azure)
      storage.access_key = "myteststorage"
      storage.access_secret = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
      storage.save!
      params = {
        "file_name"   => "some_file_name.jpg",
        "file_size"   => (258 * 1024 * 1024).to_s,
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
      info["type"].should eq("chunked_upload")
      info["residence"].should eq("AzureStorage")
      sig = info["signature"].as_h
      sig["verb"].as_s.should eq("PUT")
      sig["url"].as_s.size.should eq(0)
      upload = Model::Upload.find!(info["upload_id"].as_s)

      params = {
        "part"    => Base64.strict_encode(UUID.random.to_s),
        "file_id" => "some_file_md5_hash",
      }

      pinfo = Uploads::PartInfo.new(params["file_id"], 1, params["part"])
      uinfo = Uploads::UpdateInfo.new(params["file_id"], 1, "some-random-resumable-id", [pinfo], [1], false)

      resp = client.patch(
        path: "#{Uploads.base_route}/#{upload.id}?#{HTTP::Params.encode(params)}",
        body: uinfo.to_json,
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)
      info = JSON.parse(resp.body).as_h
      info["type"].should eq("part_upload")
      sig = info["signature"].as_h
      sig["verb"].as_s.should eq("PUT")
      sig["url"].as_s.size.should be > 0
      uri = URI.parse(sig["url"].as_s)
      uri.host.should eq(sprintf("%s.blob.core.windows.net", "myteststorage"))
      qparams = URI::Params.parse(uri.query || "")
      qparams["blockid"].should eq(params["part"])

      params = {
        "part" => "finish",
      }
      resp = client.get(
        path: "#{Uploads.base_route}/#{upload.id}/edit?#{HTTP::Params.encode(params)}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)
      info = JSON.parse(resp.body).as_h
      info["type"].should eq("finish")
      info["body"].should_not be_nil
    end
  end
end
