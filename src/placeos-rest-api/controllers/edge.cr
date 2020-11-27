require "hound-dog"
require "placeos-core/client"

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

      getter discovery : HoundDog::Discovery

      def initialize(@discovery : Api::Discovery::Core)
        @discovery.callbacks << ->rebalance(Array(HoundDog::Node))
      end

      def add_edge_connection(edge_id : String, socket : HTTP::WebSocket)
        edge_lock.synchronize do
          edge_sockets[edge_id] = socket
          new_core_connection(edge_id, core_discovery.find(edge_id))
        end
      end

      def new_core_connection(edge_id : String, node : HoundDog::Service::Node)
        uri = node[:uri].dup
        uri.query("edge_id=#{edge_id}")
        uri.path("/api/v1/edge")

        edge_lock.synchronize do
          edge_socket = edge_sockets[edge_id]
          core_socket = HTTP::Websocket.new(uri)

          # Link core to edge
          core_socket.on_message { |message| edge_socket.send(message) }
          core_socket.on_binary { |bytes| edge_socket.stream &.write(bytes) }

          # Link edge to core
          edge_socket.on_message { |message| core_socket.send(message) }
          edge_socket.on_binary { |bytes| core_socket.stream &.write(bytes) }

          core_sockets[edge_id]?.try(&.close) rescue nil
          core_sockets[edge_id] = core_socket
        end

        spawn { core_socket.run }

        core_socket
      end

      def rebalance(node : Array(HoundDog::Node))
        Log.info { "rebalancing edge connections" }
        edge_lock.synchronize do
          edge_mapping.each do |edge_id, core_node|
            new_core = core_discovery.find(edge_id)
            new_core_connection(edge_id, new_core) unless new_core[:name] == core_node[:name]
          end
        end
      end
    end

    # Validate the present of the id and check the secret before routing to core
    ws("/", :edge) do |_ws|
    end
  end
end
