require "http"
require "http/server/handler"

module PlaceOS::Api
  module SSE
    # Represents an SSE client connection
    class Connection
      @mutex = Mutex.new
      @closed = false
      @closed_channel = Channel(Nil).new(1)
      property on_close : Proc(Nil) = -> { }

      def initialize(@io : IO)
        spawn_reader
      end

      # Spawns reader fiber to detect client disconnects
      private def spawn_reader
        spawn do
          begin
            # Read any incoming data to detect disconnects
            buffer = Bytes.new(128)
            while @io.read(buffer) > 0
              # SSE clients shouldn't send data except for initial request
            end
          rescue IO::EOFError | IO::Error
            # Normal disconnect
          ensure
            close
          end
        end
      end

      # Close connection and clean up
      def close
        return if @closed
        @closed = true
        @on_close.call
        @io.close rescue nil
        @closed_channel.send(nil) rescue nil
      end

      # Check if connection is closed
      def closed?
        @closed
      end

      # Wait until connection is closed
      def wait
        @closed_channel.receive unless closed?
      end

      # Send SSE-formatted message
      def send(data : String, id : String? = nil, event : String? = nil, retry : Int32? = nil)
        @mutex.synchronize do
          return if closed?
          build_message(event, data, id, retry)
          @io.flush
        end
      rescue ex : IO::Error
        close
      end

      # Format message according to SSE spec
      private def build_message(event, data, id, retry)
        @io << "id: #{id.gsub(/\R/, " ")}\n" if id
        @io << "retry: #{retry}\n" if retry
        @io << "event: #{event.gsub(/\R/, " ")}\n" if event

        data.each_line do |line|
          @io << "data: #{line.chomp("\r")}\n"
        end

        @io << '\n'
      end
    end

    # Manages multiple SSE connections
    class SSEChannel
      @connections = [] of Connection
      @mutex = Mutex.new

      # Add connection to channel
      def add(connection)
        @mutex.synchronize do
          @connections << connection
          connection.on_close = -> { remove(connection) }
        end
      end

      # Remove connection from channel
      def remove(connection)
        @mutex.synchronize do
          @connections.delete(connection)
        end
      end

      # Broadcast message to all connections
      def broadcast(data : String, id = nil, event = nil, retry = nil)
        @mutex.synchronize do
          @connections.reject! do |conn|
            if conn.closed?
              true
            else
              conn.send(event, data, id, retry) rescue true
              false
            end
          end
        end
      end

      # Get current connection count
      def size
        @mutex.synchronize { @connections.size }
      end
    end

    # Helper to upgrade HTTP response to SSE
    def self.upgrade_response(response : HTTP::Server::Response, &block : Connection ->)
      # Set required SSE headers
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["Connection"] = "keep-alive"
      response.status = HTTP::Status::OK

      # Upgrade connection
      response.upgrade do |io|
        conn = Connection.new(io)
        block.call(conn) # Pass connection to block
        conn.wait        # Keep fiber alive until connection closes
      end
    end
  end
end
