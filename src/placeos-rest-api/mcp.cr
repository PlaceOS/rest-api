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

    There is one toolbox per API resource. Every call is made as the signed in user,
    with their permissions. List results are paginated: follow the `Link` header (or use
    `X-Total-Count`) to fetch more.

    Module state and debug logs are also resources (see resources/templates/list):
    placeos://modules/{id}/state/{key} and placeos://systems/{sys_id}/{module_slug}/{key}
    can be subscribed to for changes, placeos://modules/{id}/logs{?seconds,level} captures a module's
    debug output for a number of seconds. Use resources over function calls where available.
    Capture logs using a subagent if you want to execute commands during a capture.

    Each subscribed resource is sent at least one notifications/resources/updated after
    subscriptions/listen is acknowledged, so subscribe first and read the resource when its
    update arrives, there's no need to read it beforehand.
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
      mcp.instructions = "#{INSTRUCTIONS}\n\n#{mcp.toolbox_instructions}"
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

  # Module state resources can be subscribed to. State changes are published on
  # redis, so the instance holding a client's `subscriptions/listen` stream sees
  # changes made anywhere. Access is checked by reading the resource first.
  #
  # Every subscribed resource is notified once the listen is acknowledged, so clients
  # read after subscribing without missing a change. The driver subscription also
  # delivers an existing value once redis has registered the channel, which covers
  # changes made before then, so a resource with a value can be notified twice.
  def self.watch_state : Nil
    ActionController::MCPServer.watch("placeos://modules/{id}/state/{key}") do |variables, _request, changed|
      subscriptions = WebSocket::Session.subscriptions
      subscription = subscriptions.subscribe(variables["id"], variables["key"]) { |_, _| changed.call }
      changed.call
      -> { subscriptions.unsubscribe(subscription); nil }
    end

    # follows the module if another is assigned to the system's module slot
    ActionController::MCPServer.watch("placeos://systems/{sys_id}/{module_slug}/{key}") do |variables, _request, changed|
      module_name, index = Driver::Proxy::RemoteDriver.get_parts(variables["module_slug"])
      subscriptions = WebSocket::Session.subscriptions
      subscription = subscriptions.subscribe(variables["sys_id"], module_name, index, variables["key"]) { |_, _| changed.call }
      changed.call
      -> { subscriptions.unsubscribe(subscription); nil }
    end
  end

  configure
  watch_state
end
