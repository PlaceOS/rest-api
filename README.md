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
request bodies: omitting `organisation_id` selects the authenticated domain's
owner for every role, including partner and management staff, even when grants
provide access to other organisations. This flag remains off by default
until ownership data has been reconciled.

Partner and management staff discover organisations and pass an explicit ID
when viewing resources outside their authenticated domain's organisation:

```http
GET /api/engine/v2/organisations/current
GET /api/engine/v2/organisations
GET /api/engine/v2/systems?organisation_id=<organisation-uuid>
GET /api/engine/v2/systems/<system-id>?organisation_id=<organisation-uuid>
```

Discovery returns minimal selector records. `/organisations/current` includes
`selection_required` and `selected_organisation_id`. Selection is per request;
login Host and token authority stay fixed. A domain without ownership reaches
no estate and requires reconciliation. Malformed or repeated selectors return
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

Zone-wide execution authorises Operate on the addressed zone and intersects
OAuth/API-key write scopes. It validates target ownership and runtime aliases
without requiring separate operation grants on each system or module.

The legacy booking prompt channel remains available for the existing driver
only after checking the addressed system owner and both invited system/event
capabilities. Other signals remain domain-scoped under enforcement. Driver
subscription updates are tracked separately and are not required for this bridge.

## Ownership reconciliation

Cluster administrators can repair legacy ownership through
`/api/engine/v2/reconciliation`, including while enforcement is disabled. These
routes require a live management-domain administrator and intersect OAuth and
API-key scopes. Partner administrators and delegated organisation managers cannot
use them. Inventory, preview and receipts require read access to `reconciliation`
or `organisations`; apply requires write access.

1. `GET /reconciliation` lists unowned resources and conflicting references. Use
   `resource_type`, `resource_id`, `limit` and `offset` to review the findings.
2. `POST /reconciliation/preview` accepts an `operations` array and returns the
   complete ownership changes, blockers, access effects and a digest. Preview
   does not write data. Resolve every blocker and review the access effects.
3. `POST /reconciliation/apply` submits the same operations and digest with a
   caller-chosen `idempotency_key`. Apply rechecks the administrator, ownership
   and references under database locks. A stale preview returns 409. All resource,
   history and receipt writes commit together; retrying the same request returns
   its existing receipt. Reusing the key for a different plan returns 409.
4. `GET /reconciliation/<receipt-id>` retrieves the durable review and result.

Plans accept up to 50 operations and 500 explicit IDs per operation. The reviewed
snapshot is bounded to 5,000 rows and 16 MiB, with bounded reference fields;
oversized plans return `plan_too_large` (422). Split repairs into smaller plans
where possible. A domain or merge whose required snapshot exceeds the limit
cannot be applied through this version of the API. Access summaries contain
counts and samples of up to 20 principal IDs, with `sample_complete` indicating
whether the sample is exhaustive; receipts never contain credential secrets.

For example, claim an unowned zone tree and its dependent systems, modules and
trigger instances into an existing organisation:

```json
{
  "operations": [{
    "kind": "claim",
    "resource_type": "zone",
    "resource_ids": ["zone-1234"],
    "target_organisation_id": "00000000-0000-0000-0000-000000000001"
  }]
}
```

`reassign` and `move_zone_tree` also require the reviewed
`source_organisation_id`. `move_domain` uses `resource_type: "authority"` and
moves the domain together with its estate. This first version permits domain
moves only when the source organisation has one domain; a multi-domain estate
requires prior separation or an explicit `merge_organisations` operation with
source and target IDs. Organisation merges retain the source organisation and
its configuration. Grant collisions and changes between customer, partner-staff
and management scopes require separate resolution; apply never combines grant
permission masks or extends their expiry.

Normal resource APIs remain scoped to their selected organisation. Reconciliation
does not enable enforcement or change login domains, calendar credentials or
driver configuration. Keep enforcement disabled through the upgrade and repair
ambiguous ownership before enabling it. With enforcement disabled, legacy global
name validation is retained. Enforced organisation-local names can collide across
organisations; resolve those collisions before returning to global-name mode or
an older binary.
