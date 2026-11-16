# PlaceOS REST API

[![Build](https://github.com/PlaceOS/rest-api/actions/workflows/build.yml/badge.svg)](https://github.com/PlaceOS/rest-api/actions/workflows/build.yml)
[![CI](https://github.com/PlaceOS/rest-api/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/rest-api/actions/workflows/ci.yml)
[![Changelog](https://img.shields.io/badge/Changelog-available-github.svg)](/CHANGELOG.md)

[PlaceOS](https://place.technology/) service that provides a real-time control API.

## API Docs

https://placeos.github.io/rest-api-swagger-ui/

## MCP Server

The API is also available to LLM clients (Claude Code, Claude Desktop, VS Code,
Cursor, ...) as an [MCP](https://modelcontextprotocol.io) server at
`/api/engine/v2/mcp`, using the Streamable HTTP transport.

```shell
claude mcp add --transport http placeos https://<your-placeos-domain>/api/engine/v2/mcp
```

* **Signing in:** the client signs the user in through PlaceOS (OAuth with PKCE and
  a consent screen, served by auth). Tokens are refreshed automatically. Headless
  agents can send an API key instead, e.g. `--header "X-API-Key: <key>"`.
* **Tools:** each API resource (systems, zones, modules, ...) is a toolbox. The
  model opens the toolboxes it needs, which keeps its context small. Calls run as
  the signed in user, with their permissions.
* **Exposure:** webhooks, health checks, streaming, signalling and AI generation
  endpoints are not exposed (`@[AC::MCP(hide: true)]`).
* **Tool descriptions:** they come from the source code comments. The Docker build
  generates `mcp.yml` and ships it with the binary (`rest-api --mcp=mcp.yml`;
  override the location with `MCP_DESCRIPTION_PATH`).

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## Organisation selection

With `PLACE_TENANCY_ENFORCE=true`, REST requests operate in one organisation.
Existing users of a single organisation keep their Host, credentials, paths and
request bodies: omitting `organisation_id` selects their home organisation, even
when they hold grants to other organisations. This flag remains off by default
until ownership data has been reconciled.

Partner and management staff with structural access must first discover an
organisation and pass its ID on resource requests:

```http
GET /api/engine/v2/organisations/current
GET /api/engine/v2/organisations
GET /api/engine/v2/systems?organisation_id=<organisation-uuid>
GET /api/engine/v2/systems/<system-id>?organisation_id=<organisation-uuid>
```

Discovery returns minimal selector records. `/organisations/current` includes
`selection_required` and `selected_organisation_id`. Selection is per request;
login Host and token authority stay fixed. Missing required selection returns
400 with `code: organisation_required`; malformed or repeated selectors return
400, inaccessible resources return 404, and missing operation rights return 403.
Selection intersects grants and OAuth/API-key scopes; it does not grant access.
Authority grants remain restricted to that domain and exact permission bits.

An explicitly selected organisation can contain several domains. Domain-owned
collections include its authorised domains; use `authority_id` to narrow them.
For operations needing one domain, supply `authority_id` when the selected
organisation has several. Existing ordinary requests without an organisation
selector retain their home-domain collection behavior. Resource IDs establish
their own owning domain. Credentials, encrypted configuration and webhook
capabilities require management rights; a grant over a staff organisation alone
cannot manufacture credentials with broader partner or cluster access.

Control sockets and MCP resources capture their selected organisation and
recheck live grants, roles and API-key expiry. MQTT subscriptions are restricted
to their actual resource owners. Authentication callbacks, guest links and
WebRTC signalling remain bound to their login/capability domain. Shared driver,
repository and trigger-template catalogues keep their classified platform
permissions; raw Flux access requires cluster access. Staff API continues to
resolve organisations from its domain.

Before enabling enforcement, reconcile null organisation owners and legacy
cross-organisation zone trees, system/module references and domain-owned
references. Review those records rather than granting blanket access; invalid
references fail closed, including destructive cascades. Keep the models tenancy
branch dependency until PlaceOS/models#332 is released, then update the pin to
that release. Enable enforcement on a test cluster and run the unchanged home
request, partner selector, delegated-permission and socket regression checks
before production rollout.
