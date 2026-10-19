#!/usr/bin/env bash
# Point the car at our fleet-telemetry endpoint, and prove it took.
#
# This runs on the OPERATOR'S MACHINE, not in the cluster, and that is the design rather than a
# shortcut: the request must be signed by the Tesla application's private key, and spec §3 keeps that
# key out of the cluster. Nothing running in-cluster needs it.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE WAS REWRITTEN ON 2026-10-19
# ---------------------------------------------------------------------------
# The previous version had never completed a push against tesla-http-proxy v0.4.1. Eight separate
# defects, each found the hard way, are recorded in docs/tesla-telemetry-bringup-2026-10-19.md.
# The three that actually blocked everything:
#
#   1. It passed `--insecure --server-address`, neither of which exists. v0.4.1 deliberately ships no
#      way to disable TLS (see the comment in cmd/tesla-http-proxy/main.go), so the proxy exited on
#      flag parsing. Real flags, read from source at v0.4.1 and not guessed:
#        -cert -tls-key -key-file -host -port -timeout -verbose
#        plus -key-name / -vin / -session-cache from pkg/cli/config.go
#   2. It used the application signing key as the TLS key. The proxy refuses that outright. The TLS
#      pair is throwaway and loopback-only; `tls` below generates it.
#      Never point -tls-key and -key-file at the same file.
#   3. It posted the telemetry config bare. The proxy wants an ENVELOPE:
#        {"vins": ["..."], "config": { ...the config, including ca... }}
#      With no `config` key, params.Config unmarshals to nil and SignMessage does message["iss"]=...
#      on a nil map: the proxy panics, drops the connection with no HTTP response, and curl reports
#      `error (92) HTTP/2 stream ... INTERNAL_ERROR` or `(52) Empty reply`. That transport-shaped
#      error is what made a body-shape bug look like a network bug for the better part of an hour.
#
#   4. It omitted `ca`. Tesla REQUIRES it and answers `{"error":"ca is not a valid PEM"}`. The old
#      comment claimed omitting it was a deliberate choice to use the public CA store; that was never
#      true. `ca` is now fetched from the live endpoint by default.
#
# Everything else in this file is defensive for a reason that showed up in the incident: the bearer
# token must never reach argv (world-readable through ps) and must never be echoed by an error path;
# and every failure prints what to look at next, because the cluster side is silent by design until
# the car has actually been told.
#
# Field list and intervals are unchanged from the plan's Task 10 Step 3: fast for what the map and the
# speed graph need, slow for what never changes. See docs/teslamate-runbook.md §3 for the arithmetic.
set -euo pipefail

PROXY_URL=${TESLA_PROXY_URL:-https://127.0.0.1:4443}
FLEET_API=${TESLA_FLEET_API:-https://fleet-api.prd.eu.vn.cloud.tesla.com}
TELEMETRY_HOST=${TESLA_HOSTNAME:-telemetry.titan.arrieta.eu}
TELEMETRY_PORT=${TESLA_PORT:-443}
CONFIG=${TESLA_TELEMETRY_CONFIG:-}

: "${TESLA_APP_KEY:=$HOME/tesla/private-key.pem}"
: "${TESLA_TLS_KEY:=$HOME/tesla/tls-key.pem}"
: "${TESLA_TLS_CERT:=$HOME/tesla/tls-cert.pem}"
: "${TESLA_CA_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/tesla-telemetry/ca.pem}"

usage() {
  cat <<'EOF'
usage: tesla-push-telemetry-config.sh COMMAND

  preflight   check everything before you need it (deps, keys, proxy, ca, VINs)
  tls         generate the throwaway loopback TLS pair (refuses to reuse the app key)
  proxy       run the signing proxy (terminal 1; keep it open)
  vehicles    list the VINs the current token can see
  push [VIN]  send fleet_telemetry_config for VIN (or $TESLA_VINS, or every VIN it can see)
  status [VIN] ask Tesla what the car currently has, and whether it synced (VIN in the path, as
              Tesla requires; falls back to $TESLA_VINS, then every VIN the token can see)
  ca          fetch the CA chain the telemetry endpoint actually presents

Environment:
  TESLA_ACCESS_TOKEN   Fleet API access token for the vehicle's owner. Required for vehicles, push
                       and status. Taken from the environment, or piped on stdin, or prompted for
                       with echo off. It is never placed on a command line and never printed: this
                       token can drive the car.
  TESLA_VINS           space-separated VINs, used by push when none are given as arguments
  TESLA_APP_KEY        application private key (signs payloads)      [~/tesla/private-key.pem]
  TESLA_TLS_KEY        loopback TLS key, NOT the app key             [~/tesla/tls-key.pem]
  TESLA_TLS_CERT       loopback TLS cert                             [~/tesla/tls-cert.pem]
  TESLA_CA_FILE        CA chain handed to the car                    [~/.config/tesla-telemetry/ca.pem]
  TESLA_PROXY_URL      where the signing proxy listens        [https://127.0.0.1:4444 -> 4443]
  TESLA_TELEMETRY_CONFIG  path to a config JSON to use instead of the built-in field list
  TESLA_DRY_RUN=1      build and validate the request, do not send it

Order that works, from a clean machine:
  ./tesla-push-telemetry-config.sh tls       # once
  ./tesla-push-telemetry-config.sh proxy     # terminal 1
  ./tesla-push-telemetry-config.sh ca        # once per certificate change
  ./tesla-push-telemetry-config.sh push      # terminal 2
  ./tesla-push-telemetry-config.sh status    # until synced is true
EOF
}

die() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH"; }

# The token goes in a header FILE with 0600 perms inside a temp dir, not in argv: argv is readable by
# every user on the box through ps, and a Fleet API token can unlock the doors.
TMPDIR_TESLA=""
cleanup() { [ -n "$TMPDIR_TESLA" ] && rm -rf "$TMPDIR_TESLA"; }
trap cleanup EXIT INT TERM

workdir() {
  [ -n "$TMPDIR_TESLA" ] && return 0
  need mktemp
  TMPDIR_TESLA=$(mktemp -d) || die "mktemp failed"
  chmod 700 "$TMPDIR_TESLA"
}

read_token() {
  if [ -z "${TESLA_ACCESS_TOKEN:-}" ]; then
    if [ ! -t 0 ]; then
      TESLA_ACCESS_TOKEN=$(cat)
    else
      read -r -s -p "Fleet API access token: " TESLA_ACCESS_TOKEN </dev/tty; echo >&2
    fi
  fi
  [ -n "${TESLA_ACCESS_TOKEN:-}" ] || die "no token."
  # A token with whitespace in it was pasted wrong. It produces a malformed header, which the proxy
  # answers by resetting the stream — an error that looks nothing like its cause.
  case "$TESLA_ACCESS_TOKEN" in
    *[[:space:]]*) die "the token contains whitespace — it was pasted wrong. Re-enter it." ;;
  esac
  # Always (re)write the header file, including when the token came from the environment. Returning
  # early here is what made every request fail with `curl: option -H: error encountered when reading
  # a file`: the file simply had not been created.
  workdir
  printf 'Authorization: Bearer %s\n' "$TESLA_ACCESS_TOKEN" > "$TMPDIR_TESLA/auth.h"
  chmod 600 "$TMPDIR_TESLA/auth.h"
}

# Fail here rather than letting curl emit a confusing file error, so a future refactor that drops
# read_token from a code path is obvious instead of mysterious.
require_auth_header() {
  [ -s "$TMPDIR_TESLA/auth.h" ] || die "internal: no auth header written — read_token was skipped."
}

# curl with the token header from file. Prints "<http_code>\n<body>"; a code of 000 means transport
# failure, which for this proxy has exactly one common cause (see the hint).
api() {
  local method=$1 url=$2 data=${3:-} out code body
  require_auth_header
  local args=(-sS -k -X "$method" -H "@$TMPDIR_TESLA/auth.h" -w $'\n%{http_code}')
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
  if ! out=$(curl "${args[@]}" "$url" 2>&1); then
    note "curl could not complete: $out"
    case "$out" in
      *"Empty reply"*|*"INTERNAL_ERROR"*|*"(92)"*|*"(52)"*)
        note
        note "The signing proxy closed the connection without answering. In almost every case it"
        note "PANICKED — look at the proxy terminal. The known trigger is a request body with no"
        note "\"config\" key: the proxy signs a nil map and dies. Check the proxy's output first."
        ;;
    esac
    return 1
  fi
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  printf '%s\n%s' "$code" "$body"
}

body_config() {
  if [ -n "$CONFIG" ]; then cat "$CONFIG"; return 0; fi
  cat <<'JSON'
{
  "hostname": "telemetry.titan.arrieta.eu",
  "port": 443,
  "fields": {
    "VehicleSpeed":       {"interval_seconds": 10},
    "Location":           {"interval_seconds": 10},
    "DetailedChargeState":{"interval_seconds": 10},
    "Locked":             {"interval_seconds": 10},
    "Gear":               {"interval_seconds": 1},
    "Soc":                {"interval_seconds": 60},
    "Odometer":           {"interval_seconds": 60},
    "EstBatteryRange":    {"interval_seconds": 60},
    "CarType":            {"interval_seconds": 3600},
    "Version":            {"interval_seconds": 3600}
  }
}
JSON
}

# Tesla rejects a config with no `ca` with {"error":"ca is not a valid PEM"}. The chain the car gets
# is the one that issued the telemetry endpoint's certificate, leaf excluded.
cmd_ca() {
  need openssl
  mkdir -p "$(dirname "$TESLA_CA_FILE")"
  local raw
  raw=$(openssl s_client -showcerts -connect "${TELEMETRY_HOST}:${TELEMETRY_PORT}" \
          -servername "$TELEMETRY_HOST" </dev/null 2>/dev/null) || true
  printf '%s' "$raw" | openssl x509 -noout -subject >/dev/null 2>&1 \
    || die "no TLS handshake with ${TELEMETRY_HOST}:${TELEMETRY_PORT}. Check DNS, the Ingress, and that the wildcard is live."
  printf '%s\n' "$raw" > "$TMPDIR_TESLA/chain.txt"
  python3 - "$TMPDIR_TESLA/chain.txt" "$TESLA_CA_FILE" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
pems = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', text, re.S)
if len(pems) < 2:
    sys.exit(f"FAIL: got {len(pems)} certificate(s); need the chain with the leaf dropped")
open(sys.argv[2], 'w').write('\n'.join(pems[1:]) + '\n')
print(f"ca: {len(pems)} served, {len(pems)-1} kept (leaf dropped) -> {sys.argv[2]}")
PY
}

ensure_ca() {
  [ -s "$TESLA_CA_FILE" ] || cmd_ca
  grep -q 'BEGIN CERTIFICATE' "$TESLA_CA_FILE" \
    || die "$TESLA_CA_FILE exists but holds no certificate. Delete it and re-run 'ca'."
}

cmd_tls() {
  need openssl
  [ "$TESLA_TLS_KEY" != "$TESLA_APP_KEY" ] || die "TESLA_TLS_KEY and TESLA_APP_KEY are the same file. The proxy refuses to use one key for TLS and for command signing, and for good reason: the signing key is the credential that can drive the car."
  mkdir -p "$(dirname "$TESLA_TLS_KEY")"
  openssl ecparam -name prime256v1 -genkey -noout -out "$TESLA_TLS_KEY"
  chmod 600 "$TESLA_TLS_KEY"
  # -batch -nodes -config with an empty dn section avoids the openssl.cnf dependency that made the
  # first attempt at this need a hand-written config file.
  openssl req -x509 -new -key "$TESLA_TLS_KEY" -out "$TESLA_TLS_CERT" \
    -subj '/CN=localhost' -days 3650 -batch -nodes \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
  note "wrote $TESLA_TLS_KEY and $TESLA_TLS_CERT (self-signed, loopback only, 10 years)."
  note "If anything ever points TESLA_TLS_KEY at $TESLA_APP_KEY, stop: that is the mistake the proxy rejects."
}

cmd_proxy() {
  command -v tesla-http-proxy >/dev/null || {
    note "tesla-http-proxy is not on PATH. It cannot be installed with 'go install' from the module"
    note "path: the module has a 'replace' directive, so @v0.4.1 does not resolve. Build from a clone:"
    note
    note "  git clone --branch v0.4.1 https://github.com/teslamotors/vehicle-command /tmp/vehicle-command"
    note "  cd /tmp/vehicle-command && go build -o ~/go/bin/tesla-http-proxy ./cmd/tesla-http-proxy"
    note
    note "(The proxy's own panic traces show /tmp/vehicle-command as the build dir, which is why that"
    note "layout is the one to use.)"
    exit 1
  }
  [ -f "$TESLA_APP_KEY" ] || die "$TESLA_APP_KEY not found. That is the application private key that was paired with the car; it is not generated here."
  [ -f "$TESLA_TLS_KEY" ] && [ -f "$TESLA_TLS_CERT" ] || { note "TLS pair missing; generating."; cmd_tls; }
  [ "$TESLA_TLS_KEY" != "$TESLA_APP_KEY" ] || die "TESLA_TLS_KEY must not be the app key."

  local host port
  host=${PROXY_URL#https://}; host=${host%%/*}
  port=${host##*:}; host=${host%%:*}
  [ -n "$host" ] || host=127.0.0.1
  [ -n "$port" ] || port=4443
  note "signing proxy on ${host}:${port} — Ctrl-C to stop. Keep this terminal open; push needs it."
  note "The proxy's output is the only place a panic shows up. Watch it during a push."
  exec tesla-http-proxy -host "$host" -port "$port" \
    -cert "$TESLA_TLS_CERT" -tls-key "$TESLA_TLS_KEY" \
    -key-file "$TESLA_APP_KEY" -verbose
}

cmd_vehicles() {
  read_token
  local out code body
  out=$(api GET "$FLEET_API/api/1/vehicles") || return 1
  code=${out%%$'\n'*}; body=${out#*$'\n'}
  [ "$code" = 200 ] || { note "HTTP $code"; printf '%s\n' "$body" | jq . >&2 || true; return 1; }
  printf '%s\n' "$body" | jq -r '.response[].vin'
}

cmd_push() {
  read_token
  need jq
  local vins=( "$@" )
  if [ ${#vins[@]} -eq 0 ] && [ -n "${TESLA_VINS:-}" ]; then
    # shellcheck disable=SC2206
    vins=( $TESLA_VINS )
  fi
  if [ ${#vins[@]} -eq 0 ]; then
    note "no VIN given; discovering from the API."
    local v
    # No mapfile: macOS still ships bash 3.2, and this script runs on the operator's laptop.
    while IFS= read -r v; do [ -n "$v" ] && vins+=("$v"); done < <(cmd_vehicles)
  fi
  [ ${#vins[@]} -gt 0 ] || die "no VINs. Pass them as arguments, set TESLA_VINS, or check the token with 'vehicles'."

  ensure_ca
  workdir
  # The envelope is the whole point of this script. The proxy signs `config` and forwards
  # {vins, token} to Tesla; a body without the envelope makes it panic (see header comment).
  body_config > "$TMPDIR_TESLA/config.json"
  jq -e . "$TMPDIR_TESLA/config.json" >/dev/null || die "the config body is not valid JSON"
  jq -n --slurpfile cfg "$TMPDIR_TESLA/config.json" --rawfile ca "$TESLA_CA_FILE" \
        --argjson vins "$(printf '%s\n' "${vins[@]}" | jq -R . | jq -s .)" \
        --arg host "$TELEMETRY_HOST" --argjson port "$TELEMETRY_PORT" \
    '{vins: $vins, config: ($cfg[0] + {hostname: $host, port: $port, ca: $ca})}' \
    > "$TMPDIR_TESLA/body.json"
  jq -e '.config.ca | length > 100' "$TMPDIR_TESLA/body.json" >/dev/null \
    || die "the built body has no usable ca. Re-run 'ca'."

  if [ "${TESLA_DRY_RUN:-}" = "1" ]; then
    note "TESLA_DRY_RUN set; built request, not sent. VINs and field names below (no ca, no token):"
    jq '{vins, config: (.config | del(.ca))}' "$TMPDIR_TESLA/body.json"
    return 0
  fi

  note "posting to $PROXY_URL for: ${vins[*]}"
  local out code body
  out=$(api POST "$PROXY_URL/api/1/vehicles/fleet_telemetry_config" "@$TMPDIR_TESLA/body.json") || return 1
  code=${out%%$'\n'*}; body=${out#*$'\n'}
  note "HTTP $code"
  show_json "$body" || true
  # Tesla reports per-VIN outcome here. missing_key means that car was never paired — expected for a
  # vehicle you have not paired yet, and not something a re-push can fix.
  printf '%s\n' "$body" | jq -e '.response.updated_vehicles > 0' >/dev/null \
    || note "Nothing was updated. Check skipped_vehicles: missing_key = that car is not paired."

  note
  note "Now the car has to agree. It picks the config up on a sync, which needs it awake and online"
  note "and can take minutes. Re-run 'status' until synced is true. Until then the cluster logs being"
  note "quiet is not evidence of anything — the car has not been told yet."
}

# Tesla normally answers with JSON, but a proxy or intermediary can answer with HTML or nothing at
# all. Handing that to jq produces "Cannot index number with string" and sends you looking in the
# wrong place, so show the raw body when it is not JSON.
show_json() {
  if printf '%s' "$1" | jq . >/dev/null 2>&1; then printf '%s\n' "$1" | jq .
  else note "(not JSON)"; printf '%s\n' "$1"; return 1; fi
}

cmd_status() {
  read_token
  need jq
  local vins=( "$@" )
  if [ ${#vins[@]} -eq 0 ] && [ -n "${TESLA_VINS:-}" ]; then
    # shellcheck disable=SC2206
    vins=( $TESLA_VINS )
  fi
  if [ ${#vins[@]} -eq 0 ]; then
    note "no VIN given; discovering from the API."
    local v
    while IFS= read -r v; do [ -n "$v" ] && vins+=("$v"); done < <(cmd_vehicles)
  fi
  [ ${#vins[@]} -gt 0 ] || die "no VINs. Pass one as an argument or set TESLA_VINS."

  # The read endpoint takes the VIN in the PATH: /api/1/vehicles/{vin}/fleet_telemetry_config. The
  # VIN-less form is only the POST target; GETting it returns {"error":"not_found"}, which looks
  # exactly like "the car has no config" and is not that at all.
  local vin out code body rc=0
  for vin in "${vins[@]}"; do
    note "=== $vin ==="
    out=$(api GET "$FLEET_API/api/1/vehicles/$vin/fleet_telemetry_config") || { rc=1; continue; }
    code=${out%%$'\n'*}; body=${out#*$'\n'}
    if [ "$code" != 200 ]; then
      note "HTTP $code"; show_json "$body"; rc=1; continue
    fi
    printf '%s' "$body" | jq -e . >/dev/null 2>&1 || { note "HTTP $code but not JSON:"; show_json "$body"; rc=1; continue; }
    printf '%s\n' "$body" | jq '{synced: .response.synced, hostname: .response.config.hostname,
      port: .response.config.port, fields: (.response.config.fields | keys),
      ca_present: (.response.config.ca | length > 0)}'
    printf '%s\n' "$body" | jq -e '.response.synced' >/dev/null || {
      note "Not synced yet for $vin. Nothing downstream of this is evidence: no cluster log line"
      note "means anything until synced is true, because the car has not picked the config up."
      rc=1
    }
  done
  return $rc
}

cmd_preflight() {
  local ok=1
  for c in curl jq openssl python3; do
    if command -v "$c" >/dev/null 2>&1; then note "ok    $c"; else note "MISS  $c"; ok=0; fi
  done
  # curl needs 7.76+ for --fail-with-body; this script avoids that flag, but the version is still the
  # first thing to suspect when a request fails in a transport-shaped way.
  note "      curl $(curl --version | head -1)"
  for f in "$TESLA_APP_KEY"; do
    [ -f "$f" ] && note "ok    $f" || { note "MISS  $f (the paired application key)"; ok=0; }
  done
  [ "$TESLA_TLS_KEY" != "$TESLA_APP_KEY" ] && note "ok    TLS key is separate from the app key" \
    || { note "FAIL  TESLA_TLS_KEY == TESLA_APP_KEY"; ok=0; }
  # The proxy is fine if it is reachable OR startable. Reporting a missing binary as a failure while a
  # proxy is already answering is a false alarm — that state is exactly "you are ready to push".
  if curl -k -sS -o /dev/null --max-time 3 "$PROXY_URL/" 2>/dev/null; then
    note "ok    proxy answering at $PROXY_URL"
    if command -v tesla-http-proxy >/dev/null 2>&1; then
      note "ok    tesla-http-proxy"
    else
      note "note  tesla-http-proxy not on PATH, but something is already answering — nothing to do"
    fi
  else
    if command -v tesla-http-proxy >/dev/null 2>&1; then
      note "note  nothing at $PROXY_URL; start it with '$0 proxy'"
    else
      note "MISS  nothing at $PROXY_URL and no tesla-http-proxy to start one"
      ok=0
    fi
  fi
  [ -s "$TESLA_CA_FILE" ] && note "ok    $TESLA_CA_FILE" || note "note  no CA chain yet; 'ca' will fetch it"
  [ "$ok" = 1 ] && note "preflight: ready" || note "preflight: problems above"
  return $((1 - ok))
}

case "${1:-}" in
  push)      shift; cmd_push "$@" ;;
  status)    shift; cmd_status "$@" ;;
  proxy)     cmd_proxy ;;
  tls)       cmd_tls ;;
  ca)        workdir; cmd_ca ;;
  vehicles)  cmd_vehicles ;;
  preflight) cmd_preflight ;;
  -h|--help|"") usage; exit 0 ;;
  *) usage; exit 1 ;;
esac
