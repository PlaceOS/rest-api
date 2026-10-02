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
