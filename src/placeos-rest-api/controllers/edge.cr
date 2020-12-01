require "hound-dog"
require "placeos-core/client"
require "promise"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edge < Application
    base "/api/engine/v2/edge/"

    class_getter connection_manager : ConnectionManager { ConnectionManager.new(core_discovery) }

    # Handles the websocket proxy between Edge and Core
    #
    # TODO: Use a single socket per core
    class ConnectionManager
      Log = ::Log.for(self)

      private getter edge_mapping = {} of String => HoundDog::Service::Node
      private getter edge_sockets = {} of String => HTTP::WebSocket
      private getter core_sockets = {} of String => HTTP::WebSocket

      private getter edge_lock = Mutex.new

      getter core_discovery : Api::Discovery::Core

      def initialize(@core_discovery : Api::Discovery::Core)
        @core_discovery.callbacks << ->rebalance(Array(HoundDog::Service::Node))
      end

      def add_edge(edge_id : String, socket : HTTP::WebSocket)
        edge_lock.synchronize do
          edge_sockets[edge_id] = socket
          socket.on_close { remove(edge_id) }
          add_core(edge_id, current_node: core_discovery.find(edge_id))
        end
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
        return if node.nil? || (!reconnect && current_node && node && node[:name] == current_node[:name])

        uri = node[:uri].dup
        uri.query = "edge_id=#{edge_id}"
        uri.path = "/api/v1/edge"

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
          core_socket.on_message { |message| edge_socket.send(message) }
          core_socket.on_binary { |bytes| edge_socket.stream &.write(bytes) }

          # Link edge to core
          edge_socket.on_message { |message| core_socket.send(message) }
          edge_socket.on_binary { |bytes| core_socket.stream &.write(bytes) }

          core_sockets[edge_id]?.try(&.close) rescue nil
          core_sockets[edge_id] = core_socket
          core_socket
        end

        spawn { socket.run }
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

    # Check the validity of the token.
    # Returns the `edge_id` of the node if the token is valid.
    def self.validate_token(token : String) : String?
      parts = token.split('_')
      unless parts.size == 2
        Log.info { {message: "deformed token", token: token} }
        return
      end

      edge_id, secret = parts

      edge = Model::Edge.find(edge_id)
      if edge.nil?
        Log.info { {message: "edge not found", edge_id: edge_id} }
        return
      end

      if edge.check_secret?(secret)
        edge_id
      else
        Log.info { {message: "edge secret is invalid", edge_id: edge_id} }
        nil
      end
    end

    # Validate the present of the id and check the secret before routing to core
    ws("/", :edge) do |socket|
      token = params["token"]?
      render status: :unprocessable_entity, json: {error: "missing 'token' param"} if token.nil? || token.presence.nil?

      edge_id = Edge.validate_token(token)
      head status: :unauthorized if edge_id.nil?

      Edge.connection_manager.add_edge(edge_id, socket)
    end
  end
end
