# reference/

Vendored API specs, so the API can be read offline instead of discovered by
probing a live service.

## `jellyfin-openapi.json`

Jellyfin's OpenAPI spec. **Now fetched from the running server**, which is the
only copy guaranteed to match the deployed binary:

```sh
curl -sS http://apollo.local:8096/api-docs/openapi.json -o reference/jellyfin-openapi.json
```

`jq -r '.info.version'` currently reports **`10.11.11`**, matching the pinned
image — so this copy describes the running server exactly.

**Version trap to watch for on refresh:** the upstream published spec
(`api.jellyfin.org/openapi/jellyfin-openapi-stable.json`) reports
`info.version: 12.0.0` — the version of the *spec document*, not of Jellyfin;
the server line is 10.x and there is no Jellyfin 12. If `.info.version` ever
reads `12.0.0` again, this file came from upstream rather than the server and
runs **ahead** of what is deployed: treat it as a hint, not proof. (The known
disagreement: `POST /Startup/User` is documented with no 404 response, yet 404s
on a fresh config when `GET /Startup/User` has not run first — see CLAUDE.md.)

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

Refresh from the running server, then confirm the version matches the pinned
image — a copy reading `12.0.0` came from upstream and describes another branch:

```sh
curl -sS http://apollo.local:8096/api-docs/openapi.json -o reference/jellyfin-openapi.json
jq -r '.info.version' reference/jellyfin-openapi.json   # expect 10.11.11
```
