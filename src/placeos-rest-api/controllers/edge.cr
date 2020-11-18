require "hound-dog"
require "placeos-core/client"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edge < Application
    base "/api/engine/v2/edge/"

    class_getter core_discovery = Systems.core_discovery

    # TODO: use a single socket per core
    getter edge_sockets = {} of {String, String} => {HTTP::WebSocket, HTTP::WebSocket}

    # Validate the present of the id and check the secret before routing to core
    ws("/", :edge) do |ws|
    end
  end
end
