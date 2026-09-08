# `signage` subsystem

Routes reachable by a user whose group carries the `signage` subsystem, and the
permission bits those routes require. Routes without a subsystem or group gate
(or with no exception worth noting) are not listed.

## Two kinds of gate

Signage routes use two different mechanisms. It matters which one applies:

1. **Zone-scoped subsystem grants.** The user's `GroupUser.permissions` are
   AND-ed with a `GroupZone` grant, considering only groups whose `subsystems`
   includes `"signage"`. `GroupZone` rows cover the zone subtree. `Manage`
   satisfies every zone check. Used by `zones.cr`, `systems.cr` and the read
   path of `template_mappings.cr`. Semantics are the same as the `support`
   subsystem (see `support.md`).

2. **Group-link permissions.** Templates, playlists and media items are linked
   to groups through junction rows (`GroupSignageTemplate`, `GroupPlaylist`,
   `GroupPlaylistItem`). Access is the OR of the caller's effective membership
   bits across the linked groups. The group's `subsystems` array is **not**
   consulted, except where noted (share targets and AI generation require the
   target group to carry `"signage"`). Deny by default: a resource with no
   group links is admin/support-JWT only.

Caveats for group-link gates:

- Checks such as `enforce_template_access!(&.read?)` test the literal bit. A
  membership holding only `Manage` does not pass Read/Update/Create/Approve
  checks. `Manage` is only treated as a superset inside `ensure_group_access!`
  (the `?group_id=` unlink paths and tag maintenance).
- A `support` JWT role bypasses every gate below.

## Zones (`zones.cr`, `/api/engine/v2/zones`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `POST /` | create | Manage | the `parent_id` in the body. The `signage` tag is forced onto the new zone |
| `PATCH/PUT /:id` | update | Update or Manage in **any** signage group | no zone is consulted (coarse grant, used to set `playlists`). Changes to `tags` are silently reverted |
| `DELETE /:id` | destroy | Manage | the zone's `parent_id`. Only zones tagged `signage` can be deleted |

Root zones cannot be created or deleted via the subsystem.

## Systems (`systems.cr`, `/api/engine/v2/systems`)

The signage subsystem only applies to systems that have `signage: true`.

| Route | Action | Required | Checked against |
|---|---|---|---|
| `POST /` | create | Create covering every proposed zone (`subsystem_covers_zones?`) | `zones` in the body. Non-signage systems are rejected |
| `PATCH/PUT /:sys_id` | update | Update on any current zone, plus Update covering every zone being added | current `zones`. The system must be and stay a signage display; turning `signage` off is rejected |
| `GET /?subsystem=signage` | index | any non-zero permission | results scoped to zones reachable in the signage subsystem; empty scope returns an empty list |

Not reachable: `DELETE /:sys_id`, `add_module`, `remove_module`, `start`, `stop`, `execute`, `state` are `support` subsystem only.

## Signage display (`signage.cr`, `/api/engine/v2/signage`)

Not reachable via any group grant: `POST /:system_id/metrics` requires a `support` JWT role. `GET /:system_id` has no gate.

## Templates (`signage/templates.cr`, `/api/engine/v2/signage/templates`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `GET /` | index | Read | scoped to templates linked to groups the caller can Read. `?group_id=` is 403 without Read on that group |
| `GET /:id` | show | Read | any linked group. `shared_with` lists all linked groups, including ones the caller is not in |
| `POST /` | create | Create on `group_id` | `group_id` is mandatory for non-support callers. Auto-links the template |
| `PATCH/PUT /:id` | update | Update | any linked group |
| `DELETE /:id/draft` | destroy_draft | Update | any linked group |
| `POST /:id/approve` | approve | Approve | any linked group |
| `DELETE /:id` | destroy | Delete on any linked group; with `?group_id=`, Delete or Manage on that group | with `group_id` it unlinks; the template is deleted when the last link goes |
| `POST /share?items=&to=` | share | Share or Manage on the target group, plus Read/Share/Manage on each item's linked groups | **target group must carry the `signage` subsystem** and be in the same authority. Only approved templates can be shared |
| `GET /approvers?group_id=` | approvers | any membership of the group | returns users with Approve or Manage, climbing to the nearest ancestor with approvers |
| `POST /:id/request_approval?group_id=` | request_approval | any membership of the group | no permission on the template itself is checked |

## Template mappings (`signage/template_mappings.cr`, `/api/engine/v2/signage/template_mappings`)

Reads have two paths OR-ed together. Writes use only the template's group links; zone grants do not help.

| Route | Action | Required | Checked against |
|---|---|---|---|
| `GET /` | index | Read on a group linked to the template, **or** Read on the mapping's zone (or one of the display's zones) within `signage` or `support` | zone scope expands down the zone tree; both empty returns an empty list |
| `GET /:id` | show | same dual path as index | unrelated zones do not grant visibility; mappings of unlinked templates are admin only |
| `POST /` | create | Create | any group linked to the template being applied. No check on the target zone/system |
| `PATCH/PUT /:id` | update | Update | any linked template group. Only `schedule` is mutable |
| `DELETE /:id` | destroy | Delete | any linked template group. Zone viewers are explicitly 403 |

## Playlists (`signage/playlists.cr`, `/api/engine/v2/signage/playlists`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `GET /` | index | Read | scoped to playlists linked to readable groups. `?group_id=` is 403 without Read on it |
| `GET /:id` | show | Read | any linked group |
| `GET /:id/media`, `GET /:id/media/revisions` | media, media_revisions | Read | any linked group. Media items are hydrated even when not shared with the caller's group |
| `POST /` | create | Create on `group_id` | `group_id` mandatory for non-support callers |
| `PATCH/PUT /:id` | update | Update | any linked group |
| `POST /:id/media` | update_media | Update | any linked group |
| `POST /:id/media/schedule` | schedule_media | Update | any linked group |
| `PATCH /:id/media/schedule/:item_id` | update_schedule | Update | any linked group |
| `POST /:id/media/approve` | approve_media | Approve | any linked group (no dedicated group spec) |
| `DELETE /:id` | destroy | Delete on any linked group; with `?group_id=`, Delete or Manage on that group | unlink semantics as for templates |
| `POST /share?items=&to=` | share | Share or Manage on the target group, plus Read/Share/Manage on each playlist's linked groups | **target group must carry the `signage` subsystem** and be in the same authority |
| `GET /approvers?group_id=` | approvers | any membership of the group | |
| `POST /:id/media/request_approval?group_id=` | request_approval | any membership of the group | no permission on the playlist is checked. Note this route is absent from the `can_write` scope list |

## Media (`signage/playlist_media.cr`, `/api/engine/v2/signage/media`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `GET /` | index | Read | scoped to items linked to readable groups. `?group_id=` is 403 without Read |
| `GET /tags`, `GET /tag_counts` | tags, tag_counts | Read | same scoping as index |
| `GET /:id` | show | Read | any linked group. The `playlists` list is filtered to playlists in readable groups |
| `GET /:id/thumbnail` | thumbnail | none | no read gate; any user in the authority can fetch the signed URL |
| `POST /` | create | Create on `group_id` | `group_id` mandatory for non-support callers |
| `PATCH/PUT /:id` | update | Update | any linked group |
| `DELETE /:id` | destroy | Delete on any linked group; with `?group_id=`, Delete or Manage on that group | unlink; deleted when the last link goes |
| `PATCH /tags` | rename_tag | Read and Update on `group_id` (Manage covers both) | without `group_id` admin/support only |
| `DELETE /tags` | remove_tag | Read and Update on `group_id`; Read and Delete when `remove_media=true` | without `group_id` admin/support only |
| `POST /share?items=&to=` | share | Share or Manage on the target group, plus Read/Share/Manage on each item's linked groups | **target group must carry the `signage` subsystem** |

## AI (`signage/ai.cr`, `/api/engine/v2/signage/ai`)

| Route | Action | Required | Checked against |
|---|---|---|---|
| `POST /generate` | generate | Create on `group_id` | **the group must carry the `signage` subsystem** and be in the caller's authority. `group_id` is mandatory for non-support callers |
| `POST /edit` | edit | Create on `group_id` as above, plus Read across the groups linked to the media item that owns the source upload (unless the caller uploaded it) | the item must be supplied, reference the upload, and be linked to at least one group |
| `GET /jobs/:id`, `POST /jobs/:id/cancel`, `POST /jobs/:id/claim` | | job owner only | no group path |

Not reachable via group grants: `GET /jobs?mine=false` and `GET /usage` are `check_support` (JWT role).

## Not gated by groups at all

- `signage/ai_providers.cr`: admin JWT for writes, support JWT for reads.
- `signage/plugins.cr`: writes use the legacy org-zone scheme (`current_user.groups` against zone metadata) or a support JWT. Neither subsystem grants access. Reads have no gate.

## Routes that consult any subsystem

| Route | Behaviour |
|---|---|
| `GET /api/engine/v2/groups/current?subsystem=signage` | Filters the caller's groups to those carrying the subsystem. Any non-zero membership qualifies. |
| `GET /api/engine/v2/oauth_apps/` | Lists apps whose `subsystems` overlap the union of subsystems across the caller's groups, plus apps with no subsystems. No permission bit or zone involved. Other `oauth_apps` routes are admin only. |
| `POST /api/engine/v2/group_zones/` | Requires Manage on the target group **and** that the zone is already reachable within some subsystem of a group the caller manages. |
