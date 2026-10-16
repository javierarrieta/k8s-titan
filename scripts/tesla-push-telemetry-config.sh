#!/usr/bin/env bash
# Push fleet_telemetry_config to the car, then wait until the car agrees.
#
# This runs on the OPERATOR'S MACHINE, not in the cluster, and that is not laziness — it is the
# design. The request must be signed by the Tesla application's private key, and spec §3 decided that
# key never enters the cluster: nothing running here needs it, and a signing key in a pod is a key on
# a machine this repo describes as public-internet. No container image exists for the signing proxy
# either (verified: no Docker Hub repo for teslamotors/vehicle-command, and release v0.4.1 ships no
# assets), so there is nothing to pull even if we wanted to.
#
# WHY THERE IS A SCRIPT AT ALL. The plan for this task was a curl one-liner, and the one-liner has two
# problems worth engineering around. The bearer token on a command line is visible in `ps` to every
# user on the box and lands in shell history forever; here it comes from the environment or stdin.
# And the JSON body is thirty-odd lines of field names that Tesla rejects silently — a typo'd field is
# accepted by the API and simply never arrives, which is the worst possible failure mode for a
# telemetry pipeline. So the body lives in one file, reviewed once, and this script only transports it.
#
# The field list is the one from the plan's Task 10 Step 3, and the intervals are a deliberate mix:
# fast for the things the map and the speed graph need, slow for the things that never change. Tesla
# bills streaming signals at $1 per 150,000, so this is not the expensive half of the bill — polling
# is. See docs/teslamate-runbook.md for the arithmetic.
set -euo pipefail

PROXY=${TESLA_PROXY_URL:-https://127.0.0.1:4443}
CONFIG=${TESLA_TELEMETRY_CONFIG:-}

usage() {
  cat <<'EOF'
usage:
  tesla-push-telemetry-config.sh push     send fleet_telemetry_config and wait for the car
  tesla-push-telemetry-config.sh status   ask the car what it currently has, and whether it synced
  tesla-push-telemetry-config.sh proxy    start the signing proxy this script talks to

  TESLA_ACCESS_TOKEN=<fleet api access token>   required for push and status. Read from the
                                        environment, never put it on the command line: argv is
                                        world-readable through ps and this token can drive the car's
                                        settings. If it is not set, you will be prompted on /dev/tty
                                        with echo off.
  TESLA_PROXY_URL=https://127.0.0.1:4443        where the signing proxy listens
  TESLA_TELEMETRY_CONFIG=path.json              override the built-in field list
  TESLA_APP_KEY=~/tesla/private-key.pem         application private key, for `proxy`
  TESLA_PROXY_CERT=~/tesla/proxy-cert.pem       the cert Tesla issued for your application domain,
                                                for `proxy`

Where the token comes from: it must be a Fleet API access token for the vehicle's owner, minted by
your own application — the same OAuth grant TeslaMate performed at sign-in. TeslaMate keeps its copy
in the database, encrypted with ENCRYPTION_KEY, and reading it back out is more work than doing the
authorization-code flow again in a browser with TESLA_AUTH_CLIENT_ID and the redirect URI shown on
TeslaMate's sign-in page. Do not reach for the old Owner-API bearer; those are what this whole
migration is replacing.
EOF
}

read_token() {
  if [ -n "${TESLA_ACCESS_TOKEN:-}" ]; then return 0; fi
  if [ ! -t 0 ]; then
    TESLA_ACCESS_TOKEN=$(cat)   # so you can pipe: cat token | ./this.sh push
  else
    read -r -s -p "Fleet API access token: " TESLA_ACCESS_TOKEN </dev/tty; echo >&2
  fi
  [ -n "${TESLA_ACCESS_TOKEN:-}" ] || { echo "FAIL: no token."; exit 1; }
}

# The proxy is TLS-terminated with a certificate Tesla does not chain to publicly, which is exactly
# what --insecure here is for. It is a loopback hop, not a trust decision about Tesla.
cmd_proxy() {
  command -v tesla-http-proxy >/dev/null || {
    echo "tesla-http-proxy is not on PATH. Build it once:"
    echo "  go install github.com/teslamotors/vehicle-command/cmd/tesla-http-proxy@v0.4.1"
    echo "then re-run '$0 proxy'."
    exit 1
  }
  : "${TESLA_APP_KEY:=$HOME/tesla/private-key.pem}"
  : "${TESLA_PROXY_CERT:=$HOME/tesla/proxy-cert.pem}"
  for f in "$TESLA_APP_KEY" "$TESLA_PROXY_CERT"; do
    [ -f "$f" ] || { echo "FAIL: $f not found. The cert is the one Tesla gave you when you paired";
                     echo "the virtual key at https://tesla.com/_ak/<your application domain>."; exit 1; }
  done
  host=${PROXY#https://}; host=${host%%/*}
  echo "signing proxy on $host — Ctrl-C to stop. Keep this terminal open; push needs it running."
  exec env TESLA_HTTP_PROXY_TLS_CERT="$TESLA_PROXY_CERT" \
           TESLA_HTTP_PROXY_TLS_KEY="$TESLA_APP_KEY" \
           TESLA_HTTP_PROXY_HOST=127.0.0.1 TESLA_HTTP_PROXY_PORT="${host#*:}" \
    tesla-http-proxy --insecure --server-address "$host"
}

body() {
  if [ -n "$CONFIG" ]; then cat "$CONFIG"; return; fi
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

# `ca` is deliberately absent from the body. Omitting it is what tells the vehicle to validate the
# telemetry endpoint against the publicly trusted CA chain instead of a pinned one — the assumption
# the spec flags as unproven until check_server_cert.sh has been run against the live hostname. If
# the car connects and fleet-telemetry rejects the handshake, that assumption is the first suspect.
cmd_push() {
  read_token
  body | jq . >/dev/null || { echo "FAIL: the config body is not valid JSON"; exit 1; }
  echo "posting to $PROXY ..."
  curl -sS --fail-with-body -k --request POST \
    --header "Authorization: Bearer $TESLA_ACCESS_TOKEN" \
    --header "Content-Type: application/json" \
    --data @- "$PROXY/api/1/vehicles/fleet_telemetry_config" <<<"$(body)" | jq .
  echo
  echo "Now wait for the car. It only picks the config up on a sync, which can take a few minutes and"
  echo "needs the car awake and online. Re-run '$0 status' until synced is true — until then nothing"
  echo "in the cluster logs is evidence of anything, because the car has not been told yet."
}

cmd_status() {
  read_token
  curl -sS -k --header "Authorization: Bearer $TESLA_ACCESS_TOKEN" \
    "$PROXY/api/1/vehicles/fleet_telemetry_config" | jq '{response: {synced: .response.synced, config: .response.config | {hostname, port, fields: (.fields | keys)}}}'
}

case "${1:-}" in
  push)   cmd_push ;;
  status) cmd_status ;;
  proxy)  cmd_proxy ;;
  -h|--help|"") usage; exit 0 ;;
  *) usage; exit 1 ;;
esac
