# `support` subsystem

Routes reachable by a user whose group carries the `support` subsystem, and the
permission bits those routes require. Routes without a subsystem gate (or with
no exception worth noting) are not listed.

## How grants resolve

A user's effective permissions on a zone within a subsystem are computed by
`Group.resolve_subsystem_permissions` (see `utilities/group_permissions.cr`):

- Only groups whose `subsystems` array includes `"support"` contribute.
- The user's `GroupUser.permissions` are AND-ed with the `GroupZone.permissions`
  on the zone. Both sides must carry the bit (specs refer to this as "both
  sides").
- A `GroupZone` on a zone covers that zone's whole subtree, unless a
  more-specific row (or a `deny` row) for the same group sits below it.
- Membership of an ancestor group counts (closest explicit `GroupUser` wins).
- `Manage` satisfies every zone-scoped check (`subsystem_grants_on_zones?`).

Common gate behaviour:

| Rule | Detail |
|---|---|
| Verb mapping | `verb_permission`: POST = Create, PUT/PATCH = Update, DELETE = Delete, GET = None (so a GET gated on `verb_permission` needs an explicit Read override or Manage). |
| JWT bypass | Most gates skip the check for a `support` JWT role; a few require `admin` (noted below). |
| Legacy path | `ensure_support_access!` also accepts the legacy `authority.config["org_zone"]` + `current_user.groups` scheme before the subsystem check. |
| Deny by default | An empty zone list never passes. Resources with no zone scope (modules attached to no system, `driver-`/`user-` parents, root zones) are admin/support-JWT only. |
| Zone OR semantics | `subsystem_grants_on_zones?` passes if **any** listed zone carries the bit. |
| Zone cover semantics | `subsystem_covers_zones?` (used when assigning zones) requires **every** zone to be granted, or be an ancestor of a granted zone that is also in the list. |

## Zones (`zones.cr`, `/api/engine/v2/zones`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `POST /` | create | Create | the `parent_id` in the body |
| `PATCH/PUT /:id` | update | Update | the zone itself |
| `DELETE /:id` | destroy | Delete | the zone's `parent_id` |

Notes:
- Root zones (no parent) cannot be created or deleted via the subsystem. Delete of a root zone needs an admin JWT.
- Support users may edit `tags` (unlike signage users).
- Re-parenting on update is not re-checked against the destination parent (the legacy path does re-check).

Not reachable via subsystem grants:
- `GET /:id/triggers` and `POST /:id/exec/:module_slug/:method` are `check_support` (JWT role only). Spec asserts 403.
- `GET /` without `tags` or `parent_id` is support-JWT only. `?group_id=` requires Read on that group (group membership, not a zone grant).

## Systems (`systems.cr`, `/api/engine/v2/systems`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `POST /` | create | Create, covering every proposed zone | `zones` in the body (`subsystem_covers_zones?`) |
| `PATCH/PUT /:sys_id` | update | Update on any current zone, plus Update covering every zone being added | current `zones`; added zones checked with `within: updated.zones` |
| `DELETE /:sys_id` | destroy | Delete | the system's zones |
| `PUT /:sys_id/module/:module_id` | add_module | Update | the system's zones |
| `DELETE /:sys_id/module/:module_id` | remove_module | Delete | the system's zones |
| `POST /:sys_id/start`, `POST /:sys_id/stop` | start, stop | Operate | the system's zones |
| `POST /:sys_id/:module_slug/:method` | execute | Operate | the system's zones |
| `GET /:sys_id/functions/:module_slug` | functions | Operate | the system's zones |
| `GET /:sys_id/:module_slug` | state | Read | the system's zones |
| `GET /:sys_id/:module_slug/:key` | state_lookup | Read | the system's zones |
| `GET /?group_id=` | index | Read on the group (literal bit, Manage alone does not pass) | group membership; results scoped to the group's `GroupZone` anchors |
| `GET /?subsystem=support` | index | any non-zero permission | results scoped to zones reachable in that subsystem; empty scope returns an empty list, not 403 |

Notes:
- `destroy`, `add_module` and `remove_module` bypass on an **admin** JWT, not support, and their legacy path requires admin.
- `create` with an empty `zones` list is always 403 for subsystem users.
- Zones already on a system are never re-checked on update; only additions are.
- `functions` still filters privileged driver functions by JWT role only.
- `GET /` with neither `group_id` nor `subsystem` is unscoped.

Not reachable via subsystem grants: `GET /:sys_id/zones`, `GET /:sys_id/metadata`, `GET /:sys_id/settings` are admin JWT only.

## Modules (`modules.cr`, `/api/engine/v2/modules`)

Zones for every gate are the union of the module's `control_system_id` system zones and the zones of every system that references the module. A module attached to no system has no zone scope and is admin/support-JWT only.

| Route | Action | Required |
|---|---|---|
| `POST /` | create | Create |
| `PATCH/PUT /:id` | update | Update, checked before and after `assign_attributes` (old and new system zones) |
| `DELETE /:id` | destroy | Delete |
| `GET /:id` | show | Read |
| `GET /:id/state`, `GET /:id/state/:key` | state, state_lookup | Read |
| `POST /:id/ping` | ping | Operate |
| `POST /:id/exec/:method` | execute | Operate |
| `POST /:id/load` | load | Operate |
| `POST /:id/start`, `POST /:id/stop` | start, stop | Operate. Checked inside the action; a no-op start/stop returns 200 without a check |
| `GET /:id/settings` | settings | Update (a write bit on a read route). Encrypted values are still masked by role |
| `GET /?control_system_id=` | index | Read on that system's zones |
| `GET /` | index | Read on at least one zone; 403 when the caller has none. Results are scoped to those zones and **logic modules are excluded** (`no_logic` is forced) |

Not reachable via subsystem grants: `GET /:id/error` is `check_support` (JWT role). Spec asserts 403 even with Manage on the module's zone.

## Settings (`settings.cr`, `/api/engine/v2/settings`)

Zones come from the setting's `parent_id`: `zone-` resolves to the zone, `sys-` to the system's zones, `mod-` to the module's systems' zones. `driver-` and `user-` parents have no zone scope and are always 403 for subsystem users.

| Route | Action | Required |
|---|---|---|
| `GET /:id` | show | Read on the parent's zones. Values are decrypted per the caller's role |
| `GET /?parent_id=` | index | Read on the zones of **every** supplied parent |
| `POST /` | create | Create on the parent's zones |
| `PATCH/PUT /:id` | update | Update on the parent's zones, checked before and after `assign_attributes` |
| `DELETE /:id` | destroy | Delete on the parent's zones |

Notes:
- Writes bypass on an **admin** JWT only, and the legacy path requires admin.
- Encrypted settings are admin only. The `encryption_level.none?` check runs before the subsystem check, so Manage on the zone does not help.

Not reachable via subsystem grants: `GET /` without `parent_id` (search) is support JWT only. `GET /:id/history` is admin only.

## Metadata (`metadata.cr`, `/api/engine/v2/metadata`)

Same `parent_id` to zone resolution as settings. The subsystem check is skipped entirely when the model already allows the write (`user_can_update?` / `user_can_create?`: editors list, ownership of a `user-` parent, support role).

| Route | Action | Required |
|---|---|---|
| `PATCH /:id` | merge | Update on the parent's zones |
| `PUT /:id` | update | Update on the parent's zones |
| `PATCH /:id/name` | rename | Update on the parent's zones (no dedicated spec) |
| `DELETE /:id` | destroy | Delete on the parent's zones. Own user metadata (`parent_id == current user id`) skips the check |

Notes:
- The legacy fallback applies only to `zone-` parents under the org zone, so `sys-`/`mod-` parents are subsystem-or-nothing for non-support users.
- Reads (`GET /:id`, `/:id/children`, `/:id/history`, `/:name/bulk`) have no zone gate.

## System triggers (`system-triggers.cr`, `/api/engine/v2/systems/:sys_id/triggers`)

Zones are always the parent control system's zones.

| Route | Action | Required |
|---|---|---|
| `GET /` | index | Read |
| `GET /:trig_id` | show | Read |
| `POST /` | create | Create |
| `PATCH/PUT /:trig_id` | update | Update |
| `DELETE /:trig_id` | destroy | Delete |

Notes:
- `webhook_secret` is only returned when the caller has Read (or a support JWT). A Create-only or Update-only grant succeeds but gets the secret stripped from the response.
- A trigger instance belonging to a different system returns 404, not 403, even for admins.

## Assets (`assets.cr`, `/api/engine/v2/assets`)

Checked against the asset's `zone_id` plus its `zones` array (any one suffices). An asset with no zones is unreachable.

| Route | Action | Required |
|---|---|---|
| `POST /` | create | Create |
| `PATCH/PUT /:id` | update | Update, checked before and after `assign_attributes` (source and destination zones) |
| `DELETE /:id` | destroy | Delete |
| `POST /bulk` | bulk_create | Create per asset; one failure 403s the request |
| `PATCH/PUT /bulk` | bulk_update | Update per asset, before and after assignment |
| `DELETE /bulk` | bulk_destroy | Delete per asset |

`GET /` and `GET /:id` are not subsystem scoped. They are scoped to the caller's authority (show returns 404 for another authority's asset).

## Asset types, categories, purchase orders

All three check against the authority's **org zone** (`authority.config["org_zone"]`). With no org zone configured every write is 403.

### Asset types (`asset_types.cr`, `/api/engine/v2/asset_types`)

| Route | Required on org zone |
|---|---|
| `POST /` | Create |
| `PATCH/PUT /:id` | Update |
| `DELETE /:id` | Delete |

Another authority's asset type returns 404 even with Manage on the org zone. Reads are authority scoped, not subsystem gated.

### Asset categories (`asset_categories.cr`, `/api/engine/v2/asset_categories`)

| Route | Required on org zone |
|---|---|
| `POST /` | Create |
| `PATCH/PUT /:id` | Update |
| `DELETE /:id` | Delete |

Update/destroy of another authority's category is 403 even with the bit. Reads have no gate.

### Asset purchase orders (`asset_purchase_orders.cr`, `/api/engine/v2/asset_purchase_orders`)

The only asset controller where reads are also gated.

| Route | Required on org zone |
|---|---|
| `GET /`, `GET /:id` | Read (a Create-only grant is denied) |
| `POST /` | Create |
| `PATCH/PUT /:id` | Update |
| `DELETE /:id` | Delete |

## Uploads (`uploads.cr`, `/api/engine/v2/uploads`)

The uploader always has access to their own upload. For non-owners, checked against the org zone.

| Route | Action | Required on org zone |
|---|---|---|
| `GET /:id/edit` | edit | Update (the gate hard-codes Update for every non-DELETE method) |
| `PATCH /:id` | update | Update |
| `PUT /:id` | finished | Update |
| `DELETE /:id` | destroy | Delete |

Not reachable via subsystem grants: `GET /:id/url` and `GET /:id/download` on private uploads dispatch on the upload's own `permissions` to `check_admin` / `check_support` (JWT role only).

## Users (`users.cr`, `/api/engine/v2/users`)

Checked against the org zone.

| Route | Action | Required on org zone |
|---|---|---|
| `POST /` | create | Create |
| `DELETE /:id` | destroy | Delete |
| `POST /:id/revive` | revive | Create (POST verb), not Update |
| `PATCH/PUT /:id` | update | Update. Self-update needs no grant. Target must be in the caller's authority |

Notes:
- Subsystem creators cannot set admin attributes (`sys_admin`, `support`, `groups`, `login_name`); the new user is forced into the caller's authority.
- Another authority's user id returns 404 even with full Manage.

Not reachable via subsystem grants: `POST/DELETE /:id/resource_token` are admin only. Spec asserts 403 with Manage on the org zone and with a support JWT.

## Pending mails (`pending_mails.cr`, `/api/engine/v2/emails`)

Checked against the mail's `zones` (any one suffices). A mail with no zones is unreachable.

| Route | Action | Required |
|---|---|---|
| `DELETE /:id` | destroy | Delete |
| `POST /:id/reject` | reject | Update |
| `POST /:id/sent` | sent | Update (no dedicated spec) |

Notes:
- `GET /:id` has no zone gate. Any user in the authority can read any of its mail.
- `GET /?group_id=` requires Read on the group (membership, not subsystem) and filters to that group's `GroupZone` anchors.

Not reachable via subsystem grants: `DELETE /cleanup` is `check_support` (JWT role).

## Signage template mappings (`signage/template_mappings.cr`)

The one signage route the `support` subsystem reaches: `GET /api/engine/v2/signage/template_mappings` and `GET .../:id` are visible when the caller has Read on the mapping's zone (or one of the display's zones) within `signage` **or** `support`. Writes use the template's group links and ignore zone grants. See `signage.md`.

## Routes that consult any subsystem

These mechanisms match the caller's groups' `subsystems` array without caring which subsystem it is.

| Route | Behaviour |
|---|---|
| `GET /api/engine/v2/groups/current?subsystem=support` | Filters the caller's groups to those carrying the subsystem. Any non-zero membership qualifies. |
| `GET /api/engine/v2/oauth_apps/` | Lists apps whose `subsystems` overlap the union of subsystems across all the caller's groups (`User#subsystem_access`), plus apps with no subsystems. No permission bit and no zone involved. All other `oauth_apps` routes are admin only. |
| `POST /api/engine/v2/group_zones/` | Requires Manage on the target group **and** that the zone is already reachable by the caller within some subsystem of a group they manage (`user_can_delegate_zone?`). Reachability only; the bits being delegated are not compared. |
