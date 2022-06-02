require "hound-dog"

module PlaceOS::Api
  ###########################################################################
  # Edge Connection Management
  #
  # Handles the websocket proxy between Edge and Core
  #
  # TODO: Use a single socket per core
  class Edges::ConnectionManager
    Log = ::Log.for(self)

    private getter edge_mapping = {} of String => HoundDog::Service::Node
    private getter edge_sockets = {} of String => HTTP::WebSocket
    private getter core_sockets = {} of String => HTTP::WebSocket

    private getter edge_lock = Mutex.new(protection: :reentrant)

    getter core_discovery : Api::Discovery::Core

    def initialize(@core_discovery : Api::Discovery::Core)
      @core_discovery.callbacks << ->rebalance(Array(HoundDog::Service::Node))
    end

    def add_edge(edge_id : String, socket : HTTP::WebSocket)
      Log.debug { {edge_id: edge_id, message: "adding edge socket"} }
      edge_lock.synchronize do
        edge_sockets[edge_id] = socket
        add_core(edge_id, current_node: core_discovery.find(edge_id))
      end

      socket.on_ping do |message|
        socket.pong(message) 
      end

      socket.on_close { remove(edge_id) }
    rescue e
      Log.error(exception: e) { {edge_id: edge_id, message: "while adding edge socket"} }
      remove(edge_id)
      socket.close
    end

    def remove(edge_id : String)
      edge_lock.synchronize do
        mapping = edge_mapping.delete(edge_id)
        uri = mapping.try &.[:uri].to_s

        if socket = core_sockets.delete(edge_id)
          socket.close rescue nil
          Log.info { {message: "closed socket to core", edge_id: edge_id, core_uri: uri} }
        end

        if socket = edge_sockets.delete(edge_id)
          socket.close rescue nil
          Log.info { {message: "closed socket to edge", edge_id: edge_id, core_uri: uri} }
        end
      end
    end

    def add_core(
      edge_id : String,
      rendezvous : RendezvousHash = core_discovery.rendezvous,
      current_node : HoundDog::Service::Node? = nil,
      reconnect : Bool = false
    )
      node = rendezvous[edge_id]?.try &->HoundDog::Discovery.from_hash_value(String)

      raise "no core found" if node.nil?

      # No need to change connection
      if !reconnect && core_sockets.has_key?(edge_id) && current_node && node[:name] == current_node[:name]
        return
      end

      Log.debug { {edge_id: edge_id, message: "adding core socket"} }

      uri = node[:uri]
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
              add_core(edge_id, reconnect: true) if edge_mapping.has_key?(edge_id)
            end
          rescue error
            Log.error { {
              message:  "failed to reconnect to core",
              edge_id:  edge_id,
              core_uri: edge_mapping[edge_id]?.try &.[:uri].to_s,
            } }
            remove(edge_id)
          end
        end

        # Link core to edge
        core_socket.on_message { |message|
          Log.debug { {message: "from core", packet: message} }
          edge_socket.send(message)
        }
        core_socket.on_binary { |bytes| edge_socket.stream &.write(bytes) }

        # Link edge to core
        edge_socket.on_message { |message|
          Log.debug { {message: "from edge", packet: message} }
          core_socket.send(message)
        }

        edge_socket.on_binary { |bytes| core_socket.stream &.write(bytes) }

        core_sockets[edge_id]?.try(&.close) rescue nil
        core_sockets[edge_id] = core_socket
        core_socket
      end

      Log.debug { {edge_id: edge_id, message: "successfully added edge to core connection"} }

      spawn(same_thread: true) do
        begin
          socket.run
        rescue e
          Log.error(exception: e) { "core websocket failure" }
        end
      end

      Fiber.yield
      socket
    end

    def rebalance(nodes : Array(HoundDog::Service::Node))
      Log.info { "rebalancing edge connections" }

      rendezvous = RendezvousHash.new(nodes.map(&->HoundDog::Discovery.to_hash_value(HoundDog::Service::Node)))

      edge_lock.synchronize do
        # Asynchronously refresh core connections
        Promise.map(edge_mapping) do |(edge_id, core_node)|
          begin
            Retriable.retry(max_interval: 1.seconds, max_elapsed_time: 20.seconds, on_retry: ->(e : Exception, _i : Int32, _e : Time::Span, _p : Time::Span) {
              Log.warn { {error: e.to_s, edge_id: edge_id, message: "retrying connection to core"} }
            }) do
              add_core(edge_id, current_node: core_node, rendezvous: rendezvous)
            end
          rescue error
            Log.error(exception: error) { {message: "failed to connect to core", edge_id: edge_id} }
            remove(edge_id)
          end
        end.get
      end
    end
  end
end
