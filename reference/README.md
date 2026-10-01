# reference/

Vendored API specs, so the API can be read offline instead of discovered by
probing a live service.

## `jellyfin-openapi.json`

Jellyfin's OpenAPI spec for the pinned release (currently 12.1.0). Jellyfin
publishes one file per release, so it can be vendored before the image is ever
deployed:

```sh
curl -sSfL https://repo.jellyfin.org/files/openapi/stable/jellyfin-openapi-12.1.json -o reference/jellyfin-openapi.json
jq -r '.info.version' reference/jellyfin-openapi.json   # must match the pinned image (12.1.0)
```

Once the image runs, the server's own copy is the final word on what the binary
serves. Refresh from it and expect no diff:

```sh
curl -sS http://apollo.local:8096/api-docs/openapi.json -o reference/jellyfin-openapi.json
```

Don't use `api.jellyfin.org/openapi/jellyfin-openapi-stable.json`: it follows
whatever upstream calls stable, not the pinned tag. The spec isn't complete
evidence either way: `POST /Startup/User` is documented with no 404, yet it
404s on a fresh config when `GET /Startup/User` hasn't run first (see CLAUDE.md).

**Don't read this file with WebFetch or `Read`.** At ~1.9MB it gets cut off
before `/Startup`. Query it with `jq`:

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

## `seerr-api.yml`

Seerr's OpenAPI spec, vendored from the pinned image tag (the spec file lives
at the repo root of the release tag):

```sh
curl -sSL https://raw.githubusercontent.com/seerr-team/seerr/v3.4.1/seerr-api.yml -o reference/seerr-api.yml
```

Refresh it whenever the image tag in `docker-compose.seerr.yml` changes — same
tag, always. Note `.info.version` reads `1.0.0`: that is the *API* version, not
the app release, so it cannot confirm a match the way Jellyfin's can; the URL
tag is the only version pin.

It's YAML, so `jq` needs a one-time conversion (no `yq` assumed):

```sh
python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)' \
  < reference/seerr-api.yml > /tmp/seerr-api.json
```

Or query the YAML directly — it is multi-line, so unlike the Jellyfin JSON it
is safe to grep for a path and read that line range:

```sh
grep -n -E "^  /(auth|settings)/" reference/seerr-api.yml   # locate a route
grep -n -E "^    [A-Za-z]+Settings:" reference/seerr-api.yml  # locate a schema
```

Facts already mined from it (v3.4.1), used by `seerr-bootstrap.sh`:

- `POST /auth/jellyfin` takes `serverType` as a **number** — `2` is
  `MediaServerType.JELLYFIN` (from `server/constants/server.ts` at the tag).
- `GET /settings/jellyfin/library?sync=true&enable=<id>,<id>` — `enable`
  **replaces** the enabled set; any library not listed is disabled.
- `SonarrSettings` requires `enableSeasonFolders`; `RadarrSettings` requires
  `minimumAvailability`. Both require `name/hostname/port/apiKey/useSsl/`
  `activeProfileId/activeProfileName/activeDirectory/is4k/isDefault`.
- `POST /settings/{sonarr,radarr}/test` needs only
  `{hostname, port, apiKey, useSsl}` and returns the quality profiles.
