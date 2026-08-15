# reference/

Vendored API specs, so the API can be read offline instead of discovered by
probing a live service.

## `jellyfin-openapi.json`

Jellyfin's OpenAPI spec, from
`https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json`
(fetched 2026-08-15). 294 paths, 357 schemas.

**Version trap:** this document reports `info.version: 12.0.0`. That is the
version of the *spec document*, not of Jellyfin — the server release line is
10.x and there is no Jellyfin 12. The stack is pinned to `10.11.11`, the newest
published image. So the spec runs **ahead** of the deployed server: treat it as
a strong hint, not proof, and confirm against the running instance when a
detail matters. (The known case where they disagree: `POST /Startup/User` is
documented here but 404s on 10.11.11 — see "Open / future items" in CLAUDE.md.)

**Don't read this file with WebFetch or `Read`** — it's ~1.9MB on one line, so
it truncates alphabetically, before `/Startup`. Query it with `jq`:

```sh
# every path under a tag, with its verbs
jq -r '.paths | to_entries[] | select(.key|test("^/Startup"))
       | "\(.key) [\(.value|keys|map(ascii_upcase)|join(","))]"' reference/jellyfin-openapi.json

# one operation: summary, body schema ref, documented responses
jq '.paths["/Startup/User"].post
    | {summary, operationId, responses: (.responses|keys)}' reference/jellyfin-openapi.json

# a schema's field names
jq '.components.schemas.StartupUserDto' reference/jellyfin-openapi.json

# which auth policy gates an endpoint
jq -r '.paths["/Startup/User"].post.security' reference/jellyfin-openapi.json
```

Refresh with:

```sh
curl -fsSL -o reference/jellyfin-openapi.json \
  https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json
```
