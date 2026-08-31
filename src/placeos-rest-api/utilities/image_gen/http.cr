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

      # Behind a proxy the socket is opened during construction, before the
      # lines above run, and HTTP::Client only applies its timeouts to sockets
      # it opens itself. Without this the timeouts silently do not hold on
      # exactly the deployment the proxy shard exists for, and a stalled vendor
      # keeps its fiber and its slot for good.
      if (io = client.@io).is_a?(::Socket)
        io.read_timeout = read_timeout
        io.write_timeout = read_timeout
      end
      begin
        yield client
      ensure
        client.close rescue nil
      end
    end

    # Fetch bytes we already hold a signed URL for. Crystal's HTTP::Client does
    # not follow redirects, so this follows a small number by hand: `/uploads/:id/url`
    # answers with a 303 to the storage provider.
    private def self.too_large : NoReturn
      raise Error::ImageGen::Vendor.new("image is larger than #{SIGNAGE_AI_MAX_IMAGE_BYTES // (1024 * 1024)}MB")
    end

    # Copy at most `limit` bytes, then give up. Reading the body first and
    # checking its size afterwards is not a limit: the allocation has already
    # happened, and an upload's recorded size is client supplied, so this is the
    # only place the ceiling can actually be enforced.
    private def self.read_capped(io : IO, limit : Int64) : Bytes
      buffer = IO::Memory.new
      copied = IO.copy(io, buffer, limit + 1)
      too_large if copied > limit
      buffer.to_slice
    end

    def self.get_bytes(url : String, limit : Int32 = 3) : Tuple(Bytes, String)
      current = url
      limit.times do
        uri = URI.parse(current)
        redirect = nil.as(String?)
        result = nil.as(Tuple(Bytes, String)?)

        client(uri, 60.seconds) do |http|
          # Streamed, so an oversized object is abandoned rather than buffered.
          # Encoding is left alone: asking for identity would turn off Crystal's
          # implicit decompression, and a server that ignored it would hand back
          # gzip bytes to be stored as an image. The cap below reads the
          # decompressed stream, so it holds either way.
          http.get(uri.request_target) do |response|
            if response.status.redirection? && (location = response.headers["Location"]?)
              redirect = location.starts_with?("http") ? location : uri.resolve(location).to_s
              next
            end

            raise Error::ImageGen::Vendor.new("could not read image (#{response.status_code})") unless response.success?

            # a length we can trust saves reading anything at all
            if (length = response.headers["Content-Length"]?.try(&.to_i64?)) && length > SIGNAGE_AI_MAX_IMAGE_BYTES
              too_large
            end

            body = response.body_io?
            raise Error::ImageGen::Vendor.new("image response had no body") if body.nil?
            bytes = read_capped(body, SIGNAGE_AI_MAX_IMAGE_BYTES)
            mime = response.headers["Content-Type"]? || "application/octet-stream"
            result = {bytes, mime.split(';').first.strip}
          end
        end

        if (location = redirect)
          current = location
          next
        end

        return result.not_nil!
      end
      raise Error::ImageGen::Vendor.new("too many redirects reading image")
    end

    # What the bytes actually are, rather than what the request asked for. A
    # gateway in front of a vendor may transcode, and the stored object's
    # content type has to match what a browser will be served.
    def self.mime_of(bytes : Bytes, fallback : String = "image/jpeg") : String
      return "image/png" if bytes.size > 8 && bytes[0] == 0x89 && bytes[1] == 0x50
      return "image/jpeg" if bytes.size > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8
      return "image/webp" if bytes.size > 12 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
      fallback
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
