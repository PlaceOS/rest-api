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

    Every role defaults to the organisation that owns the authenticated domain.
    To select another accessible organisation, pass organisation_id on each tool call.
    The same optional query variable selects an organisation in resource URIs.
    Staff API continues to use its domain and is not affected by this selection.

    Module state and debug logs are also resources (see resources/templates/list):
    placeos://modules/{id}/state/{key} and placeos://systems/{sys_id}/{module_slug}/{key}
    can be subscribed to for changes, placeos://modules/{id}/logs{?seconds,level} captures a module's
    debug output for a number of seconds. Use resources over function calls where available.

    Each subscribed resource is sent at least one notifications/resources/updated after
    subscriptions/listen is acknowledged, so subscribe first and read the resource when its
    update arrives, there's no need to read it beforehand.

    Read the driver source at its current commit to understand how the module
    works before live debugging. Follow the module's driver_id to its driver,
    then use the driver's repository_id and file_name to find its repository
    and source file. See CLAUDE.md or AGENTS.md at
    https://github.com/place-labs/ai-env-drivers for development and testing guidance.

    During live debugging, compare the module's state before and after running
    a function. Start a log capture in a subagent and execute the function
    while the capture runs. To read the full state by module ID, use resources/read with
    placeos://modules/{id}/state. To read it by system ID and module slug, open
    the systems toolbox and pass an argument object like this to call_read_only.

    {
      "name": "systems_state",
      "arguments": {"sys_id": "sys-FYADMGGYSm", "module_slug": "System_1"}
    }

    Clone the driver's repository, edit and test the driver, then commit and push
    the changes so PlaceOS can fetch them. If you only changed a required file or
    library, make a small edit to the driver source, such as changing a comment,
    so the commit is selectable.

    Before updating the driver, open the repositories toolbox with open_toolbox.
    Run repositories_details through call_tool with arguments like these.

    {
      "name": "repositories_details",
      "arguments": {
        "id": "repo-Fhwr6Ovf5z0",
        "driver": "drivers/place/staff_api.cr",
        "commit": "66a41ddf0f9e66df6e681be1d6916fe93d3c5768"
      }
    }

    This check compiles the driver if needed and can take 3 minutes or more.
    If it times out, retry the same check until it succeeds. Resolve any build
    errors and check the corrected commit before proceeding. After the check
    succeeds, open the drivers toolbox and run drivers_update through call_tool
    with the driver ID and the checked commit in the request body. Allow about
    10 seconds for the module to load the new code, then repeat the function
    call and check its logs.
    TEXT

  # tokens are issued by auth.cr on the same host, its issuer is scheme + host
  def self.authorization_server(request : HTTP::Request) : String
    scheme = request.headers["X-Forwarded-Proto"]?.try(&.split(',').first.strip.presence) || (Api.production? ? "https" : "http")
    "#{scheme}://#{request.hostname}"
  end

  def self.configure : Nil
    ActionController::MCPServer.tap do |mcp|
      # no namespace: the Server Card (`<PATH>/server-card`) prefixes the request host
      # reversed, so each deployment is its own publisher (`com.acme.placeos/placeos-engine`)
      mcp.server_name = "placeos-engine"
      mcp.server_version = VERSION
      mcp.server_title = "PlaceOS Building Management"
      mcp.server_description = "Configure buildings, rooms and devices, control AV and building systems, and debug their drivers"
      mcp.website_url = "https://docs.placeos.com"
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
  @@state_resource_tools : Hash(String, ActionController::MCPServer::Tool)? = nil
  STATE_TOOLS_LOCK = Mutex.new

  # Route metadata is immutable; generating source documentation belongs to
  # the build, never a subscription request. No identity or permission is cached.
  private def self.state_resource_tools : Hash(String, ActionController::MCPServer::Tool)
    STATE_TOOLS_LOCK.synchronize do
      @@state_resource_tools ||= ActionController::MCPServer.generate_description(docs: false).toolboxes.flat_map(&.tools)
        .compact_map { |tool| tool.resource.try { |uri| {uri, tool} } }.to_h
    end
  end

  # Resource notifications outlive the request that opened their stream. Reuse
  # the resource route's complete authorisation on every update, so revocation,
  # stored API-key scopes and changed ownership apply to existing subscriptions.
  private def self.state_authorizer(template : String, variables : Hash(String, String), request : HTTP::Request) : Proc(Bool)
    return -> { true } unless Utils::Tenancy.enforce?
    values = variables.dup
    origin = HTTP::Request.new(request.method, request.resource, request.headers.dup)
    origin.remote_address = request.remote_address
    tool = state_resource_tools[template]
    invoker = ActionController::MCPServer::Invoker.new(ActionController::Composition.default.handler.route_handler)
    -> { invoker.readable?(tool, values, origin) }
  end

  def self.watch_state : Nil
    ActionController::MCPServer.watch("placeos://modules/{id}/state/{key}{?organisation_id}") do |variables, request, changed|
      authorize = state_authorizer("placeos://modules/{id}/state/{key}{?organisation_id}", variables, request)
      subscriptions = WebSocket::Session.subscriptions
      subscription = subscriptions.subscribe(variables["id"], variables["key"]) { |_, _| changed.call if authorize.call }
      changed.call if authorize.call
      -> { subscriptions.unsubscribe(subscription); nil }
    end

    # follows the module if another is assigned to the system's module slot
    ActionController::MCPServer.watch("placeos://systems/{sys_id}/{module_slug}/{key}{?organisation_id}") do |variables, request, changed|
      authorize = state_authorizer("placeos://systems/{sys_id}/{module_slug}/{key}{?organisation_id}", variables, request)
      module_name, index = Driver::Proxy::RemoteDriver.get_parts(variables["module_slug"])
      subscriptions = WebSocket::Session.subscriptions
      subscription = subscriptions.subscribe(variables["sys_id"], module_name, index, variables["key"]) { |_, _| changed.call if authorize.call }
      changed.call if authorize.call
      -> { subscriptions.unsubscribe(subscription); nil }
    end
  end

  configure
  watch_state
end
