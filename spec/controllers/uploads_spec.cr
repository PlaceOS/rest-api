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
        "file_name"  => "some_file_name.jpg",
        "file_size"  => "500",
        "file_id"    => "some_file_md5_hash",
        "file_mime"  => "image/jpeg",
        "cache_etag" => "12345",
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
      model = Model::Upload.find?(info["upload_id"].as_s)
      model.should_not be_nil
      raise "will never raise" unless model
      model.cache_etag.should eq "12345"
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

      part_number = "1"
      params = {
        "part"    => part_number,
        "file_id" => "some_file_md5_hash",
      }

      pinfo = Uploads::PartInfo.new(md5: params["file_id"], part: 1)
      uinfo = Uploads::UpdateInfo.new(resumable_id: "some-random-resumable-id", part_data: [pinfo], part_list: [1])

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
      # Azure encodes the part as Base64(part.rjust(6, '0'))
      expected_block_id = Base64.strict_encode(part_number.rjust(6, '0'))
      qparams["blockid"].should eq(expected_block_id)

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

    it "should list uploads from a specific storage when storage_id is provided" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!

      # Create two storages for the same authority
      storage1 = Model::Generator.storage(authority_id: authority.id)
      storage1.is_default = true
      storage1.save!

      storage2 = Model::Generator.storage(authority_id: authority.id)
      storage2.is_default = false
      storage2.save!

      # Create uploads in both storages
      Model::Generator.upload(file_name: "file_in_storage1", storage_id: storage1.id).save!
      Model::Generator.upload(file_name: "file_in_storage2_a", storage_id: storage2.id).save!
      Model::Generator.upload(file_name: "file_in_storage2_b", storage_id: storage2.id).save!

      # List uploads from storage2
      params = HTTP::Params.encode({
        "storage_id" => storage2.id.as(String),
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "2"
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(2)
      uploads.all? { |u| u.storage_id == storage2.id }.should be_true
    end

    it "should list uploads from default storage when storage_id is not provided" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!

      # Create two storages
      storage1 = Model::Generator.storage(authority_id: authority.id)
      storage1.is_default = true
      storage1.save!

      storage2 = Model::Generator.storage(authority_id: authority.id)
      storage2.is_default = false
      storage2.save!

      # Create uploads in both storages
      Model::Generator.upload(file_name: "default_file", storage_id: storage1.id).save!
      Model::Generator.upload(file_name: "other_file", storage_id: storage2.id).save!

      # List uploads without storage_id (should use default)
      result = client.get(Uploads.base_route,
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "1"
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(1)
      uploads.first.storage_id.should eq(storage1.id)
      uploads.first.file_name.should eq("default_file")
    end

    it "should return 404 when storage_id does not exist" do
      params = HTTP::Params.encode({
        "storage_id" => "storage-nonexistent",
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.status_code.should eq(404)
      JSON.parse(result.body).as_h["error"].as_s.should contain("Storage not found")
    end

    it "should return 403 when storage_id belongs to different authority" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!

      # Create storage for a different authority
      other_authority = Model::Generator.authority
      other_authority.domain = "other.example.com"
      other_authority.save!

      other_storage = Model::Generator.storage(authority_id: other_authority.id)
      other_storage.save!

      # Try to list uploads from other authority's storage
      params = HTTP::Params.encode({
        "storage_id" => other_storage.id.as(String),
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.status_code.should eq(403)
    end

    it "should allow access to global storage (authority_id is nil)" do
      authority = Model::Authority.find_by_domain("localhost").not_nil!

      # Create a global storage (no authority_id)
      global_storage = Model::Generator.storage(authority_id: nil)
      global_storage.save!

      # Create upload in global storage
      Model::Generator.upload(file_name: "global_file", storage_id: global_storage.id).save!

      # List uploads from global storage
      params = HTTP::Params.encode({
        "storage_id" => global_storage.id.as(String),
      })

      result = client.get("#{Uploads.base_route}/?#{params}",
        headers: Spec::Authentication.headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "1"
      uploads = Array(Model::Upload).from_json(result.body)
      uploads.size.should eq(1)
      uploads.first.file_name.should eq("global_file")
    end
  end
end
