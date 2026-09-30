require "../helper"

module PlaceOS::Api
  # A real 1x1 PNG, standing in for what the browser renders.
  SCREENSHOT_TINY_PNG = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

  describe "Uploads#screenshot" do
    path = File.join(Uploads.base_route, "screenshot")
    browser = /browser:3000\/chromium\/screenshot/
    object_store = /amazonaws\.com|blob\.core\.windows\.net/

    # the domain's default storage; signed URLs point at amazonaws
    setup_storage = -> {
      authority = Model::Authority.find_by_domain("localhost").not_nil!
      Model::Generator.storage(authority_id: authority.id.as(String)).save!
    }

    # `Screenshot.capture` streams the reply (`client.post(...) { |response| }`),
    # and WebMock hands a stubbed response to that block as-is, so it has to
    # carry a `body_io` rather than a `body` string
    browser_response = ->(status : Int32, bytes : Bytes) {
      HTTP::Client::Response.new(status, headers: HTTP::Headers{"Content-Type" => "image/png"}, body_io: IO::Memory.new(bytes))
    }

    # browser stub answering with `bytes`, recording each request it sees
    stub_browser = ->(requests : Array(HTTP::Request), bodies : Array(String), bytes : Bytes) {
      WebMock.stub(:post, browser).to_return do |request|
        requests << request
        bodies << WebMock.body(request).to_s
        browser_response.call(200, bytes)
      end
    }

    before_each do
      Model::Upload.clear
      Model::Storage.clear
      # an unstubbed browser or bucket call should fail loudly
      WebMock.allow_net_connect = false
    end

    it "renders the page, stores the image and returns the upload" do
      storage = setup_storage.call
      user, headers = Spec::Authentication.authentication
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, SCREENSHOT_TINY_PNG)
      WebMock.stub(:put, object_store).to_return(body: "", status: 200)

      result = client.post(path, headers: headers, body: {
        url:  "https://www.example.com/dashboard?x=1",
        tags: ["lobby", "signage"],
      }.to_json)

      result.status_code.should eq 201
      body = JSON.parse(result.body)
      upload = Model::Upload.find!(body["id"].as_s)
      upload.upload_complete.should be_true
      upload.storage_id.should eq storage.id
      upload.uploaded_by.should eq user.id
      upload.uploaded_email.should eq user.email
      upload.file_size.should eq SCREENSHOT_TINY_PNG.size
      upload.file_md5.should eq Digest::MD5.base64digest(SCREENSHOT_TINY_PNG)
      upload.tags.should contain "screenshot"
      upload.tags.should contain "lobby"
      upload.tags.should contain "signage"
      upload.tags.size.should eq 3
      upload.public.should be_false
      upload.object_options["headers"]["Content-Type"].as_s.should eq "image/png"
      upload.object_options["permissions"].as_s.should eq "private"
      upload.file_name.should eq "screenshot-www.example.com-1920x1080.png"
      upload.object_key.should start_with "/localhost/"
      upload.object_key.should end_with ".png"
      body["upload_complete"].as_bool.should be_true

      requests.size.should eq 1
      requests.first.query_params["token"].should eq "browser-token"
      requests.first.query_params["timeout"].should eq SCREENSHOT_TIMEOUT.total_milliseconds.to_i.to_s
      JSON.parse(bodies.first)["url"].as_s.should eq "https://www.example.com/dashboard?x=1"
    end

    it "sends the viewport, format and readiness options to the browser" do
      setup_storage.call
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, SCREENSHOT_TINY_PNG)
      WebMock.stub(:put, object_store).to_return(body: "", status: 200)

      result = client.post(path, headers: Spec::Authentication.headers, body: {
        url:       "https://example.com",
        width:     1280,
        height:    720,
        scale:     2.0,
        full_page: true,
        settle:    2500,
      }.to_json)

      result.status_code.should eq 201
      sent = JSON.parse(bodies.first)
      sent["viewport"]["width"].as_i.should eq 1280
      sent["viewport"]["height"].as_i.should eq 720
      sent["viewport"]["deviceScaleFactor"].as_f.should eq 2.0
      sent["options"]["type"].as_s.should eq "png"
      sent["options"]["fullPage"].as_bool.should be_true
      sent["gotoOptions"]["waitUntil"].as_s.should eq "networkidle2"
      sent["rejectRequestPattern"].as_a.map(&.as_s).should eq ["^http:"]
      function = sent["waitForFunction"]["fn"].as_s
      function.should contain "document.fonts.ready"
      function.should contain "2500"
      sent["waitForFunction"]["timeout"].as_i.should eq 2500 + Screenshot::READY_TIMEOUT_MS

      JSON.parse(result.body)["file_name"].as_s.should eq "screenshot-example.com-1280x720.png"
    end

    it "stores a jpeg and sanitizes a custom file name" do
      setup_storage.call
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, Base64.decode(HttpMocks::TINY_JPEG))
      WebMock.stub(:put, object_store).to_return(body: "", status: 200)

      result = client.post(path, headers: Spec::Authentication.headers, body: {
        url:    "https://example.com",
        format: "jpeg",
      }.to_json)

      result.status_code.should eq 201
      JSON.parse(bodies.first)["options"]["type"].as_s.should eq "jpeg"
      upload = Model::Upload.find!(JSON.parse(result.body)["id"].as_s)
      upload.object_options["headers"]["Content-Type"].as_s.should eq "image/jpeg"
      upload.file_name.should eq "screenshot-example.com-1920x1080.jpg"
      upload.object_key.should end_with ".jpg"

      result = client.post(path, headers: Spec::Authentication.headers, body: {
        url:       "https://example.com",
        format:    "jpeg",
        file_name: "../reports/my weekly (v2).jpg",
      }.to_json)

      result.status_code.should eq 201
      Model::Upload.find!(JSON.parse(result.body)["id"].as_s).file_name.should eq "my_weekly__v2_.jpg"
    end

    it "rejects invalid requests with 400 without calling the browser" do
      setup_storage.call
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, SCREENSHOT_TINY_PNG)
      WebMock.stub(:put, object_store).to_return(body: "", status: 200)
      headers = Spec::Authentication.headers

      [
        {url: "http://example.com"},
        {url: "/relative/page"},
        {url: "https:///no-host"},
        {url: "https://example.com", width: 0},
        {url: "https://example.com", width: 99999},
        {url: "https://example.com", height: 0},
        {url: "https://example.com", scale: 10.0},
        {url: "https://example.com", settle: 20000},
        {url: "https://example.com", format: "gif"},
        {url: "https://example.com", tags: ["has space"]},
        {url: "https://example.com", tags: ["<script>"]},
      ].each do |payload|
        result = client.post(path, headers: headers, body: payload.to_json)
        result.status_code.should eq(400), "expected 400 for #{payload.to_json}, got #{result.status_code}: #{result.body}"
      end

      requests.should be_empty
      Model::Upload.count.should eq 0
    end

    it "maps a browser error to 502 and stores nothing" do
      setup_storage.call
      WebMock.stub(:post, browser).to_return { |_request| browser_response.call(500, "boom".to_slice) }
      WebMock.stub(:put, object_store).to_return(body: "", status: 200)

      result = client.post(path, headers: Spec::Authentication.headers, body: {url: "https://example.com"}.to_json)

      result.status_code.should eq 502
      Model::Upload.count.should eq 0
    end

    it "maps a browser timeout to 504 and stores nothing" do
      setup_storage.call
      WebMock.stub(:post, browser).to_return { |_request| browser_response.call(408, "timed out".to_slice) }
      WebMock.stub(:put, object_store).to_return(body: "", status: 200)

      result = client.post(path, headers: Spec::Authentication.headers, body: {url: "https://example.com"}.to_json)

      result.status_code.should eq 504
      Model::Upload.count.should eq 0
    end

    it "maps a storage rejection to 502 and removes the upload row" do
      setup_storage.call
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, SCREENSHOT_TINY_PNG)
      WebMock.stub(:put, object_store).to_return(body: "AccessDenied", status: 403)

      result = client.post(path, headers: Spec::Authentication.headers, body: {url: "https://example.com"}.to_json)

      result.status_code.should eq 502
      requests.size.should eq 1
      Model::Upload.count.should eq 0
    end

    it "maps an unreachable storage to 502 and removes the upload row" do
      setup_storage.call
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, SCREENSHOT_TINY_PNG)
      WebMock.stub(:put, object_store).to_return do |_request|
        raise IO::Error.new("connection reset by storage")
      end

      result = client.post(path, headers: Spec::Authentication.headers, body: {url: "https://example.com"}.to_json)

      result.status_code.should eq 502
      requests.size.should eq 1
      Model::Upload.count.should eq 0
    end

    it "requires authentication" do
      setup_storage.call
      requests = [] of HTTP::Request
      bodies = [] of String
      stub_browser.call(requests, bodies, SCREENSHOT_TINY_PNG)

      result = client.post(path,
        headers: HTTP::Headers{"Host" => "localhost", "Content-Type" => "application/json"},
        body: {url: "https://example.com"}.to_json)

      result.status_code.should eq 401
      requests.should be_empty
    end
  end
end
