require "http/client"
require "json"

module PlaceOS::Api
  # Renders a web page to an image using the browserless REST API
  # (`POST /chromium/screenshot`, ghcr.io/browserless/chromium).
  #
  # Page readiness: `networkidle2` (no more than 2 connections for 500ms) gets
  # the page loaded, then a single async `waitForFunction` waits for web fonts,
  # a painted frame, `settle` ms for animations and one more frame. It's one
  # function because browserless runs `waitForTimeout` *before*
  # `waitForFunction`, which is the wrong way round for a settle delay.
  module Screenshot
    Log = ::Log.for(self)

    enum Format
      Png
      Jpeg
      Webp

      def mime : String
        "image/#{to_s.downcase}"
      end

      def extension : String
        png? ? "png" : (jpeg? ? "jpg" : "webp")
      end
    end

    MAX_WIDTH         =   7680
    MAX_HEIGHT        =   4320
    MIN_SCALE         =    0.1
    MAX_SCALE         =    4.0
    DEFAULT_SETTLE_MS =   1000
    MAX_SETTLE_MS     = 10_000
    MAX_BYTES         = 50_i64 * 1024 * 1024

    # browser side limits, kept inside the job timeout so a slow page fails
    # with a useful error rather than the job being killed
    NAVIGATION_TIMEOUT_MS = 30_000
    READY_TIMEOUT_MS      =  5_000

    # blocks every plain http load: main frame redirects and subresources.
    # Internal services only speak http, so the browser can't be pointed at them.
    REJECT_REQUEST_PATTERN = ["^http:"]

    def self.request_body(url : URI, width : Int32, height : Int32, scale : Float64, format : Format, full_page : Bool, settle : Int32) : String
      ready = <<-JS
        async () => {
          const frame = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
          await document.fonts.ready;
          await frame();
          await new Promise(r => setTimeout(r, #{settle}));
          await frame();
        }
        JS

      {
        url:                  url.to_s,
        viewport:             {width: width, height: height, deviceScaleFactor: scale},
        options:              {type: format.to_s.downcase, fullPage: full_page},
        gotoOptions:          {waitUntil: "networkidle2", timeout: NAVIGATION_TIMEOUT_MS},
        waitForFunction:      {fn: ready, timeout: settle + READY_TIMEOUT_MS},
        rejectRequestPattern: REJECT_REQUEST_PATTERN,
      }.to_json
    end

    def self.capture(url : URI, width : Int32, height : Int32, scale : Float64, format : Format, full_page : Bool, settle : Int32) : Bytes
      params = URI::Params.new({"timeout" => [SCREENSHOT_TIMEOUT.total_milliseconds.to_i.to_s]})
      headers = HTTP::Headers{
        "Content-Type" => "application/json",
        # browserless echoes Accept as the response type and only accepts
        # png/jpeg/text; the stored mime comes from `format` regardless
        "Accept" => "*/*",
      }
      # a header rather than `?token=`: the shared secret is long base64 and
      # shouldn't end up in access logs
      if token = BROWSER_TOKEN
        headers["Authorization"] = "Bearer #{token}"
      end

      client = HTTP::Client.new(BROWSER_URI)
      client.connect_timeout = 5.seconds
      # the browser enforces SCREENSHOT_TIMEOUT itself, allow time for the reply
      client.read_timeout = SCREENSHOT_TIMEOUT + 10.seconds
      begin
        client.post("/chromium/screenshot?#{params}", headers: headers, body: request_body(url, width, height, scale, format, full_page, settle)) do |response|
          unless response.success?
            message = response.body_io.gets(512).to_s.strip
            Log.warn { {message: "browser screenshot failed", status: response.status_code, url: url.to_s, error: message} }
            case response.status_code
            when 408 then raise Error::GatewayTimeout.new("page did not finish rendering in time")
            when 429 then raise Error::BadGateway.new("browser is busy, try again shortly")
            else          raise Error::BadGateway.new("browser failed to render the page (#{response.status_code})")
            end
          end

          buffer = IO::Memory.new
          copied = IO.copy(response.body_io, buffer, MAX_BYTES + 1)
          raise Error::BadGateway.new("screenshot is larger than #{MAX_BYTES // (1024 * 1024)}MB") if copied > MAX_BYTES
          raise Error::BadGateway.new("browser returned an empty screenshot") if copied.zero?
          buffer.to_slice
        end
      rescue error : IO::TimeoutError
        raise Error::GatewayTimeout.new("browser did not respond in time")
      rescue error : Socket::Error
        Log.error(exception: error) { "browser unreachable at #{BROWSER_URI}" }
        raise Error::BadGateway.new("browser unavailable")
      ensure
        client.close
      end
    end
  end
end
