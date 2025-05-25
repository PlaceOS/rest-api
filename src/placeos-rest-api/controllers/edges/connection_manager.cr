require "redis_service_manager"
require "tasker"

module PlaceOS::Api
  ###########################################################################
  # Edge Connection Management
  #
  # Handles the websocket proxy between Edge and Core
  #
  # TODO: Use a single socket per core
  class Edges::ConnectionManager
    Log = ::Log.for(self)

    private getter edge_sockets = {} of String => HTTP::WebSocket
    private getter core_sockets = {} of String => HTTP::WebSocket
    private getter ping_tasks : Hash(String, Tasker::Repeat(Nil)) = {} of String => Tasker::Repeat(Nil)

    private getter edge_lock = Mutex.new(protection: :reentrant)

    getter core_discovery : Clustering::Discovery

    def initialize(@core_discovery : Clustering::Discovery)
      spawn { detect_rebalance }
    end

    # detect rebalance - loop every 6 seconds
    protected def detect_rebalance
      current_nodes = core_discovery.nodes
      loop do
        begin
          sleep 6.seconds
          new_nodes = core_discovery.nodes
          if current_nodes != new_nodes
            current_nodes = new_nodes
            rebalance
          end
        rescue error
          Log.warn(exception: error) { "error rebalancing edge connections" }
        end
      end
    rescue error
      Log.warn(exception: error) { "error starting rebalance detection loop" }
      sleep 1.seconds
      spawn { detect_rebalance }
    end

    def add_edge(edge_id : String, socket : HTTP::WebSocket)
      Log.debug { {edge_id: edge_id, message: "adding edge socket"} }
      edge_lock.synchronize do
        if existing_socket = edge_sockets[edge_id]?
          existing_socket.on_close { }
          existing_socket.close rescue nil
        end

        edge_sockets[edge_id] = socket
        if existing_socket
          link_edge(socket, edge_id)
        else
          node_found = core_discovery.find(edge_id)
          add_core(edge_id, uri: node_found)
          ping_tasks[edge_id] = Tasker.every(10.seconds) do
            socket.ping rescue nil
            core_sockets[edge_id].ping rescue nil
            nil
          end

          socket.on_ping do |string|
            core_sockets[edge_id].ping(string)
          rescue e
            Log.error(exception: e) { {edge_id: edge_id, message: "while forwarding ping to core socket"} }
          end

          socket.on_pong do |string|
            ::PlaceOS::Model::Edge.update(edge_id, {last_seen: Time.utc, online: true})
            begin
              core_sockets[edge_id].pong(string)
            rescue e
              Log.error(exception: e) { {edge_id: edge_id, message: "while forwarding pong to core socket"} }
            end
          end
        end
      end

      socket.on_close do
        ::PlaceOS::Model::Edge.update(edge_id, {last_seen: Time.utc, online: false})
        edge_lock.synchronize { remove(edge_id) if socket == edge_sockets[edge_id]? }
      end
    rescue e
      Log.error(exception: e) { {edge_id: edge_id, message: "while adding edge socket"} }
      remove(edge_id)
    end

    def remove(edge_id : String)
      edge_lock.synchronize do
        if task = ping_tasks.delete(edge_id)
          task.cancel
        end

        if socket = core_sockets.delete(edge_id)
          socket.on_close { }
          socket.close rescue nil
          Log.info { {message: "closed socket to core", edge_id: edge_id} }
        end

        if socket = edge_sockets.delete(edge_id)
          socket.on_close { }
          socket.close rescue nil
          Log.info { {message: "closed socket to edge", edge_id: edge_id} }
        end
      end
    end

    def add_core(
      edge_id : String,
      uri : URI,
      reconnect : Bool = false,
    )
      # No need to change connection
      if !reconnect && core_sockets.has_key?(edge_id)
        return
      end

      Log.debug { {edge_id: edge_id, message: "adding core socket"} }

      uri.query = "edge_id=#{edge_id}"
      uri.path = "/api/core/v1/edge/control"

      socket = edge_lock.synchronize do
        edge_socket = edge_sockets[edge_id]
        core_socket = HTTP::WebSocket.new(uri)
        core_socket.on_close do
          begin
            Retriable.retry(
              max_interval: 5.seconds,
              max_elapsed_time: 1.minute,
              on_retry: ->(error : Exception, _i : Int32, _e : Time::Span, _p : Time::Span) {
                Log.warn { {error: error.to_s, edge_id: edge_id, message: "reconnecting edge to core"} }
              }) do
              add_core(edge_id, core_discovery.find(edge_id), reconnect: true) if core_sockets[edge_id]? == core_socket
            end
          rescue error
            Log.error { {
              message:  "failed to reconnect to core",
              edge_id:  edge_id,
              core_uri: uri.to_s,
            } }
            remove(edge_id)
          end
        end

        # Link core to edge
        core_socket.on_message { |message|
          Log.debug { {message: "from core", packet: message} }
          edge_sockets[edge_id].send(message)
        }
        core_socket.on_binary do |bytes|
          Log.debug { {message: "Got binary packet from core", size: bytes.size, edge_active: !edge_socket.closed?} }
          edge_socket.stream &.write(bytes)
        end

        core_socket.on_ping { |string| edge_socket.ping(string) }
        core_socket.on_pong { |string| edge_socket.pong(string) }

        # Link edge to core
        link_edge(edge_socket, edge_id)

        if existing_sock = core_sockets[edge_id]?
          existing_sock.on_close { }
          existing_sock.close
        end
        core_sockets[edge_id] = core_socket
        core_socket
      end

      Log.debug { {edge_id: edge_id, message: "successfully added edge to core connection"} }

      spawn do
        begin
          socket.run
        rescue e
          Log.error(exception: e) { "core websocket failure" }
        end
      end

      Fiber.yield
      socket
    end

    def link_edge(edge_socket, edge_id)
      edge_socket.on_message { |message|
        Log.debug { {message: "from edge", packet: message} }
        core_sockets[edge_id].send(message)
      }

      edge_socket.on_binary { |bytes| core_sockets[edge_id].stream &.write(bytes) }
    end

    def rebalance
      Log.info { "rebalancing edge connections" }
      edge_lock.synchronize do
        sockets = edge_sockets.values + core_sockets.values
        pings = ping_tasks.values

        @edge_sockets = {} of String => HTTP::WebSocket
        @core_sockets = {} of String => HTTP::WebSocket
        @ping_tasks = {} of String => Tasker::Repeat(Nil)

        pings.each &.cancel
        sockets.each do |socket|
          socket.on_close { }
          socket.close
        end
      end
    end
  end
end
