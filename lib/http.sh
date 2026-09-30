# Shared by arr-bootstrap.sh, seerr-bootstrap.sh, arr-indexers.sh: sourced,
# not run directly. The sourcing script must define info() and DRY_RUN before
# mask()/wait_for() are called.

mask() {
  # Redacts credential-shaped fields before a value is ever printed (dry-run,
  # --verbose, or an error body) — never the request itself.
  printf '%s' "$1" | jq -c '
    if type == "object" then
      (if has("fields") then
         .fields |= map(if (.name // "" | test("password|apiKey"; "i")) then .value = "***" else . end)
       else . end)
      | (if has("password") then .password = "***" else . end)
      | (if has("apiKey") then .apiKey = "***" else . end)
    else . end' 2>/dev/null || echo '<unprintable>'
}

wait_for() {
  # wait_for <name> <base-url>
  local name="$1" base="$2" i probe
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for ${name} at ${base}"
    return 0
  fi
  for i in $(seq 1 90); do
    # /ping is unauthenticated and only 200s once the app is genuinely serving.
    # A TCP connect is not enough: these apps accept connections well before
    # they finish migrating their database. The JSON shape is checked too, since
    # a reverse proxy or a wrong port can 200 with something else entirely.
    if probe=$(curl -fsS --max-time 5 "${base}/ping" 2>/dev/null) \
       && printf '%s' "$probe" | jq -e '.status == "OK"' >/dev/null 2>&1; then
      info "${name} ready at ${base}"
      return 0
    fi
    if [ "$i" -eq 90 ]; then
      echo "ERROR: ${name} did not answer at ${base}/ping after 180s." >&2
      echo "       Check: docker logs ${name}" >&2
      exit 1
    fi
    sleep 2
  done
}
