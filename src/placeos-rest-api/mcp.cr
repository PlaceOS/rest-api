require "action-controller/mcp"

# Exposes the REST API to LLM clients as an MCP server (Streamable HTTP).
#
# Controllers are toolboxes and their routes tools, see `ActionController::MCPServer`.
# Users authenticate with auth.cr (OAuth + PKCE): unauthenticated requests are
# challenged with the protected resource metadata, which auth.cr serves (nginx
# routes `/.well-known/*` to auth). API keys (`X-API-Key`) also work.
module PlaceOS::Api::MCP
  PATH = "/api/engine/v2/mcp"

  # any authenticated user, exercising the full `authorize!` checks
  AUTH_PROBE = "/api/engine/v2/users/current"

  INSTRUCTIONS = <<-TEXT
    PlaceOS is a building automation and workplace platform. This server exposes the
    PlaceOS REST API: systems (rooms and spaces), zones (buildings, levels, areas),
    modules (device drivers), users, groups, assets, signage and more.

    Tools are grouped into toolboxes, one per API resource. Call list_toolboxes to see
    what is available, open_toolbox to load the tools for a resource and close_toolbox
    once you no longer need them. Every call is made as the signed in user, with their
    permissions.
    TEXT

  # tokens are issued by auth.cr on the same host, its issuer is scheme + host
  def self.authorization_server(request : HTTP::Request) : String
    scheme = request.headers["X-Forwarded-Proto"]?.try(&.split(',').first.strip.presence) || (Api.production? ? "https" : "http")
    "#{scheme}://#{request.hostname}"
  end

  def self.configure : Nil
    ActionController::MCPServer.tap do |mcp|
      mcp.server_name = "placeos"
      mcp.server_version = VERSION
      mcp.instructions = INSTRUCTIONS
      mcp.description_path = ENV["MCP_DESCRIPTION_PATH"]? || "mcp.yml"
      mcp.auth_probe = AUTH_PROBE
      mcp.resource_metadata = ->(request : HTTP::Request) do
        ActionController::MCPServer::ResourceMetadata.new(
          authorization_servers: [authorization_server(request)],
          scopes_supported: ["public"],
        )
      end
    end
  end

  def self.mount(router : ActionController::Router) : ActionController::MCPServer::Transport
    ActionController::MCPServer.mount(router, PATH)
  end

  configure
end
