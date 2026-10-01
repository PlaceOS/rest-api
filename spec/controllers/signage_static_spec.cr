require "../helper"

module PlaceOS::Api
  # A real 1x1 PNG, standing in for what the browser renders.
  STATIC_TINY_PNG = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

  describe "Signage static media" do
    static_path = ->(system : Model::ControlSystem, item_id : String?) { "#{Signage.base_route}/#{system.id}/static/#{item_id}" }
    eink_path = ->(system : Model::ControlSystem, item_id : String?) { "#{Signage.base_route}/#{system.id}/samsung/eink/#{item_id}" }
    browser = /browser:3000\/chromium\/screenshot/
    object_store = /amazonaws\.com/
    # what an e-ink display sends: no credentials, just the domain
    anonymous = HTTP::Headers{"Host" => "localhost"}

    # the domain's default storage; signed URLs point at amazonaws
    setup_storage = -> {
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      Model::Generator.storage(authority_id: authority.id.as(String)).save!
    }

    # a sign with optional pixel dimensions
    display = ->(width : Int32?, height : Int32?, orientation : Model::Playlist::Orientation) {
      system = Model::Generator.control_system
      system.signage = true
      system.orientation = orientation
      system.sign_width = width
      system.sign_height = height
      system.save!
    }
    plain_display = -> { display.call(nil, nil, Model::Playlist::Orientation::Unspecified) }

    # browser stub answering with a png, recording each request body it sees
    stub_browser = ->(bodies : Array(String), delay : Time::Span) {
      WebMock.stub(:post, browser).to_return do |request|
        bodies << WebMock.body(request).to_s
        sleep delay
        HTTP::Client::Response.new(200, headers: HTTP::Headers{"Content-Type" => "image/png"}, body_io: IO::Memory.new(STATIC_TINY_PNG))
      end
    }

    # an image upload in the domain's storage
    image_upload = ->(storage : Model::Storage) {
      upload = Model::Generator.upload(storage_id: storage.id, permissions: Model::Upload::Permissions::None)
      upload.upload_complete = true
      upload.save!
    }

    webpage_item = ->(orientation : Model::Playlist::Orientation) {
      item = Model::Generator.item(media_uri: "https://www.example.com/dashboard")
      item.orientation = orientation
      item.save!
    }

    capture_name = ->(item : Model::Playlist::Item, width : Int32, height : Int32) { "signage-#{item.id}-#{width}x#{height}.png" }

    # the captures stored for an item at a size, newest first
    captures = ->(item : Model::Playlist::Item, width : Int32, height : Int32) {
      Model::Upload.where(uploaded_by: Signage::STATIC_UPLOADER, file_name: capture_name.call(item, width, height)).order(created_at: :desc).to_a
    }

    # a previous capture of the item at a size, created `age` ago
    previous_capture = ->(storage : Model::Storage, item : Model::Playlist::Item, width : Int32, height : Int32, age : Time::Span) {
      upload = Model::Generator.upload(storage_id: storage.id, permissions: Model::Upload::Permissions::None, file_name: capture_name.call(item, width, height))
      upload.uploaded_by = Signage::STATIC_UPLOADER
      upload.tags = ["screenshot", Signage::STATIC_TAG]
      upload.upload_complete = true
      upload.save!
      Model::Upload.update(upload.id, created_at: age.ago)
      Model::Upload.find!(upload.id.as(String))
    }

    before_each do
      Model::Playlist::Item.clear
      Model::Upload.clear
      Model::Storage.clear
      Model::ControlSystem.clear
      # an unstubbed browser or bucket call should fail loudly
      WebMock.allow_net_connect = false
    end

    describe "GET /:system_id/static/:item_id" do
      it "redirects to a temporary link for an image item" do
        headers = Spec::Authentication.headers
        storage = setup_storage.call
        upload = image_upload.call(storage)
        item = Model::Generator.item(media_id: upload.id).save!

        result = client.get(static_path.call(plain_display.call, item.id), headers: headers)

        result.status_code.should eq 303
        location = result.headers["Location"]
        location.should contain "amazonaws.com"
        location.should contain storage.bucket_name
        location.should contain upload.object_key
      end

      it "redirects to the URI of an external image" do
        headers = Spec::Authentication.headers
        item = Model::Generator.item(media_uri: "https://images.example.com/poster.jpg")
        item.media_type = Model::Playlist::Item::MediaType::ExternalImage
        item.save!

        result = client.get(static_path.call(plain_display.call, item.id), headers: headers)

        result.status_code.should eq 303
        result.headers["Location"].should eq "https://images.example.com/poster.jpg"
      end

      it "captures a web page at the sign's pixel dimensions" do
        headers = Spec::Authentication.headers
        storage = setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        bodies = [] of String
        stub_browser.call(bodies, 0.seconds)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)

        result = client.get(static_path.call(display.call(1200, 1600, Model::Playlist::Orientation::Unspecified), item.id), headers: headers)

        result.status_code.should eq 303
        bodies.size.should eq 1
        sent = JSON.parse(bodies.first)
        sent["url"].as_s.should eq "https://www.example.com/dashboard"
        sent["viewport"]["width"].as_i.should eq 1200
        sent["viewport"]["height"].as_i.should eq 1600
        sent["options"]["type"].as_s.should eq "png"

        stored = captures.call(item, 1200, 1600)
        stored.size.should eq 1
        upload = stored.first
        upload.upload_complete.should be_true
        upload.storage_id.should eq storage.id
        upload.tags.should contain "screenshot"
        upload.tags.should contain Signage::STATIC_TAG
        upload.file_size.should eq STATIC_TINY_PNG.size
        result.headers["Location"].should contain upload.object_key

        # the item isn't modified
        Model::Playlist::Item.find!(item.id.as(String)).media_id.should be_nil
      end

      it "sizes the capture by the sign's orientation when it has no dimensions" do
        headers = Spec::Authentication.headers
        setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        bodies = [] of String
        stub_browser.call(bodies, 0.seconds)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)

        sign = display.call(nil, nil, Model::Playlist::Orientation::Portrait)
        client.get(static_path.call(sign, item.id), headers: headers).status_code.should eq 303

        sent = JSON.parse(bodies.first)
        sent["viewport"]["width"].as_i.should eq 1080
        sent["viewport"]["height"].as_i.should eq 1920
      end

      it "falls back to the item's orientation when the sign's is unspecified" do
        headers = Spec::Authentication.headers
        setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Portrait)
        bodies = [] of String
        stub_browser.call(bodies, 0.seconds)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)

        client.get(static_path.call(plain_display.call, item.id), headers: headers).status_code.should eq 303

        sent = JSON.parse(bodies.first)
        sent["viewport"]["width"].as_i.should eq 1080
        sent["viewport"]["height"].as_i.should eq 1920
      end

      it "keeps a capture per size so differently sized signs don't replace each other's" do
        headers = Spec::Authentication.headers
        setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        bodies = [] of String
        stub_browser.call(bodies, 0.seconds)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)
        small = display.call(1200, 1600, Model::Playlist::Orientation::Unspecified)
        large = display.call(2560, 1440, Model::Playlist::Orientation::Unspecified)

        2.times do
          client.get(static_path.call(small, item.id), headers: headers).status_code.should eq 303
          client.get(static_path.call(large, item.id), headers: headers).status_code.should eq 303
        end

        bodies.size.should eq 2
        captures.call(item, 1200, 1600).size.should eq 1
        captures.call(item, 2560, 1440).size.should eq 1
      end

      it "serves a capture that is still within the cache period" do
        headers = Spec::Authentication.headers
        storage = setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        capture = previous_capture.call(storage, item, 1920, 1080, 10.minutes)
        # no browser stub: a capture attempt would fail the request

        result = client.get("#{static_path.call(plain_display.call, item.id)}?expires_after=60", headers: headers)

        result.status_code.should eq 303
        result.headers["Location"].should contain capture.object_key
      end

      it "replaces an expired capture, removing the old one" do
        headers = Spec::Authentication.headers
        storage = setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        expired = previous_capture.call(storage, item, 1920, 1080, 2.hours)
        bodies = [] of String
        stub_browser.call(bodies, 0.seconds)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)
        WebMock.stub(:delete, object_store).to_return(body: "", status: 204)

        result = client.get("#{static_path.call(plain_display.call, item.id)}?expires_after=60", headers: headers)

        result.status_code.should eq 303
        bodies.size.should eq 1
        stored = captures.call(item, 1920, 1080)
        stored.size.should eq 1
        stored.first.id.should_not eq expired.id
        result.headers["Location"].should contain stored.first.object_key
        Model::Upload.find?(expired.id.as(String)).should be_nil
        Model::Playlist::Item.find?(item.id.as(String)).should_not be_nil
      end

      it "serves the previous capture when the browser fails" do
        headers = Spec::Authentication.headers
        storage = setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        expired = previous_capture.call(storage, item, 1920, 1080, 2.hours)
        # streamed reply, so the stub needs a `body_io`
        WebMock.stub(:post, browser).to_return { HTTP::Client::Response.new(500, body_io: IO::Memory.new("boom")) }

        result = client.get(static_path.call(plain_display.call, item.id), headers: headers)

        result.status_code.should eq 303
        result.headers["Location"].should contain expired.object_key
        Model::Upload.find?(expired.id.as(String)).should_not be_nil
      end

      it "fails when the browser fails and there is no previous capture" do
        headers = Spec::Authentication.headers
        setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        # streamed reply, so the stub needs a `body_io`
        WebMock.stub(:post, browser).to_return { HTTP::Client::Response.new(500, body_io: IO::Memory.new("boom")) }

        result = client.get(static_path.call(plain_display.call, item.id), headers: headers)

        result.status_code.should eq 502
        Model::Upload.count.should eq 0
      end

      it "captures once when requests arrive together" do
        headers = Spec::Authentication.headers
        setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        sign = plain_display.call
        bodies = [] of String
        stub_browser.call(bodies, 1.second)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)

        results = Channel(HTTP::Client::Response).new
        3.times do
          spawn { results.send client.get(static_path.call(sign, item.id), headers: headers) }
        end
        responses = Array.new(3) { results.receive }

        responses.map(&.status_code).should eq [303, 303, 303]
        bodies.size.should eq 1
        Model::Upload.count.should eq 1
        upload = captures.call(item, 1920, 1080).first
        responses.each(&.headers["Location"].should(contain(upload.object_key)))
      end

      it "rejects web pages that aren't https" do
        headers = Spec::Authentication.headers
        setup_storage.call
        item = Model::Generator.item(media_uri: "http://intranet.example.com/page").save!

        client.get(static_path.call(plain_display.call, item.id), headers: headers).status_code.should eq 406
      end

      it "rejects media that can't be displayed statically" do
        headers = Spec::Authentication.headers
        storage = setup_storage.call
        upload = image_upload.call(storage)
        item = Model::Generator.item(media_id: upload.id)
        item.media_type = Model::Playlist::Item::MediaType::Video
        item.save!

        client.get(static_path.call(plain_display.call, item.id), headers: headers).status_code.should eq 406
      end

      it "rejects a cache period below the minimum" do
        headers = Spec::Authentication.headers
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)

        client.get("#{static_path.call(plain_display.call, item.id)}?expires_after=1", headers: headers).status_code.should eq 400
      end

      it "404s for missing items, items on another domain and missing systems" do
        headers = Spec::Authentication.headers
        sign = plain_display.call
        other = Model::Generator.authority("https://other-#{random_name}.example.com").save!
        foreign = Model::Generator.item(authority: other).save!
        local = webpage_item.call(Model::Playlist::Orientation::Landscape)

        client.get(static_path.call(sign, "playlist_items-missing"), headers: headers).status_code.should eq 404
        client.get(static_path.call(sign, foreign.id), headers: headers).status_code.should eq 404
        client.get("#{Signage.base_route}/sys-missing/static/#{local.id}", headers: headers).status_code.should eq 404
      end

      it "requires authentication" do
        Spec::Authentication.headers
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)

        client.get(static_path.call(plain_display.call, item.id), headers: anonymous).status_code.should eq 401
      end
    end

    describe "GET /:system_id/samsung/eink/:item_id" do
      it "returns a manifest for the item without authentication" do
        Spec::Authentication.headers
        storage = setup_storage.call
        upload = image_upload.call(storage)
        upload.file_name = "poster.png"
        upload.save!
        item = Model::Generator.item(media_id: upload.id).save!

        result = client.get(eink_path.call(plain_display.call, item.id), headers: anonymous)

        result.status_code.should eq 200
        manifest = JSON.parse(result.body)
        manifest["program_id"].as_s.should eq "com.samsung.ios.ePaper"
        manifest["content_type"].as_s.should eq "ImageContent"
        manifest["deploy_type"].as_s.should eq "MOBILE"
        manifest["version"].as_i.should eq 1
        manifest["name"].as_s.should eq item.id
        manifest["create_time"].as_s.should match /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/

        schedule = manifest["schedule"][0]
        schedule["start_date"].as_s.should eq "1970-01-01"
        schedule["stop_date"].as_s.should eq "2999-12-31"
        schedule["start_time"].as_s.should eq "00:00:00"

        content = schedule["contents"][0]
        file_id = content["file_id"].as_s
        file_id.should match /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/
        manifest["id"].as_s.should eq file_id
        content["image_url"].as_s.should contain upload.object_key
        content["file_name"].as_s.should eq "#{file_id}.png"
        content["file_path"].as_s.should eq "#{Signage::SamsungEinkManifest::FILE_PATH}/#{file_id}/#{file_id}.png"
        content["file_size"].as_s.should eq upload.file_size.to_s
        content["duration"].as_i.should eq 60 * 60
      end

      it "takes the cache period from the path and changes the file id with the capture" do
        Spec::Authentication.headers
        storage = setup_storage.call
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)
        sign = display.call(1200, 1600, Model::Playlist::Orientation::Unspecified)
        previous_capture.call(storage, item, 1200, 1600, 20.minutes)
        bodies = [] of String
        stub_browser.call(bodies, 0.seconds)
        WebMock.stub(:put, object_store).to_return(body: "", status: 200)
        WebMock.stub(:delete, object_store).to_return(body: "", status: 204)

        # within a 30 minute cache period
        result = client.get("#{eink_path.call(sign, item.id)}/30", headers: anonymous)
        result.status_code.should eq 200
        bodies.size.should eq 0
        first = JSON.parse(result.body)
        first["schedule"][0]["contents"][0]["duration"].as_i.should eq 30 * 60

        # beyond a 15 minute cache period
        result = client.get("#{eink_path.call(sign, item.id)}/15", headers: anonymous)
        result.status_code.should eq 200
        bodies.size.should eq 1
        second = JSON.parse(result.body)
        second["id"].should_not eq first["id"]
        upload = captures.call(item, 1200, 1600).first
        second["schedule"][0]["contents"][0]["image_url"].as_s.should contain upload.object_key
      end

      it "refuses restricted media" do
        Spec::Authentication.headers
        storage = setup_storage.call
        upload = image_upload.call(storage)
        upload.permissions = Model::Upload::Permissions::Admin
        upload.save!
        item = Model::Generator.item(media_id: upload.id).save!

        client.get(eink_path.call(plain_display.call, item.id), headers: anonymous).status_code.should eq 403
      end

      it "rejects a cache period below the minimum" do
        Spec::Authentication.headers
        item = webpage_item.call(Model::Playlist::Orientation::Landscape)

        client.get("#{eink_path.call(plain_display.call, item.id)}/2", headers: anonymous).status_code.should eq 400
      end

      it "404s for items on another domain" do
        Spec::Authentication.headers
        other = Model::Generator.authority("https://other-#{random_name}.example.com").save!
        item = Model::Generator.item(authority: other).save!

        client.get(eink_path.call(plain_display.call, item.id), headers: anonymous).status_code.should eq 404
      end
    end
  end
end
