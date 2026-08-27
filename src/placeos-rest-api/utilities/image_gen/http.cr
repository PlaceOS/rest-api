require "connect-proxy"

module PlaceOS::Api::ImageGen
  # One place that builds an HTTP client for a vendor call.
  #
  # `ConnectProxy::HTTPClient` honours the proxy environment the helm chart sets,
  # which a plain `HTTP::Client` ignores. Timeouts are always explicit: no other
  # rest-api code sets a read timeout, and a vendor that stops responding would
  # otherwise hold a fiber and its slot forever.
  module Http
    CONNECT_TIMEOUT = 10.seconds

    def self.client(uri : URI, read_timeout : Time::Span = SIGNAGE_AI_READ_TIMEOUT, & : HTTP::Client -> _)
      client = ConnectProxy::HTTPClient.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = read_timeout
      client.write_timeout = read_timeout
      begin
        yield client
      ensure
        client.close rescue nil
      end
    end

    # Fetch bytes we already hold a signed URL for. Crystal's HTTP::Client does
    # not follow redirects, so this follows a small number by hand: `/uploads/:id/url`
    # answers with a 303 to the storage provider.
    def self.get_bytes(url : String, limit : Int32 = 3) : Tuple(Bytes, String)
      current = url
      limit.times do
        uri = URI.parse(current)
        response = client(uri, 60.seconds) { |http| http.get(uri.request_target) }

        if response.status.redirection? && (location = response.headers["Location"]?)
          current = location.starts_with?("http") ? location : URI.parse(current).resolve(location).to_s
          next
        end

        raise Error::ImageGen::Vendor.new("could not read image (#{response.status_code})") unless response.success?
        mime = response.headers["Content-Type"]? || "application/octet-stream"
        return {response.body.to_slice, mime.split(';').first.strip}
      end
      raise Error::ImageGen::Vendor.new("too many redirects reading image")
    end

    # Width and height straight out of the file header. The api binary is built
    # `--static` from scratch and has no image library, and we only ever deal
    # with JPEG and PNG here.
    def self.dimensions(bytes : Bytes) : Tuple(Int32, Int32)?
      return png_dimensions(bytes) if bytes.size > 24 && bytes[0] == 0x89 && bytes[1] == 0x50
      return jpeg_dimensions(bytes) if bytes.size > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8
      nil
    end

    private def self.png_dimensions(bytes : Bytes) : Tuple(Int32, Int32)?
      # IHDR is always the first chunk: width and height are big endian at 16..23
      width = IO::ByteFormat::BigEndian.decode(UInt32, bytes[16, 4])
      height = IO::ByteFormat::BigEndian.decode(UInt32, bytes[20, 4])
      {width.to_i32, height.to_i32}
    rescue
      nil
    end

    private def self.jpeg_dimensions(bytes : Bytes) : Tuple(Int32, Int32)?
      index = 2
      while index + 9 < bytes.size
        return nil unless bytes[index] == 0xFF
        marker = bytes[index + 1]
        length = IO::ByteFormat::BigEndian.decode(UInt16, bytes[index + 2, 2]).to_i

        # SOF0..SOF15, skipping the four that are not frame headers
        if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
          height = IO::ByteFormat::BigEndian.decode(UInt16, bytes[index + 5, 2]).to_i32
          width = IO::ByteFormat::BigEndian.decode(UInt16, bytes[index + 7, 2]).to_i32
          return {width, height}
        end

        index += 2 + length
      end
      nil
    rescue
      nil
    end
  end
end
