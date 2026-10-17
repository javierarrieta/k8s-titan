#!/usr/bin/env bash
# Mint a Fleet API access/refresh token pair for your own Tesla application, so TeslaMate can be
# signed in without any third party.
#
# WHY THIS EXISTS. TeslaMate v4.3.0 cannot do this itself: its sign-in page is two text boxes for an
# access token and a refresh token (elixir/lib/teslamate_web/live/signin_live/index.html.heex), and
# sign_in/2 only accepts a `%Tokens{}` pair or an email/password. Every token therefore has to be
# minted by the authorization-code grant, from a URI the application has registered with Tesla. The
# docs' answer is a third-party binary (tesla_auth); the point of this migration is that nothing
# third-party sees the car, so the grant is done here instead, with your own client id.
#
# IT ALSO DECIDES WHETHER YOUR SETUP CAN WORK AT ALL. TeslaMate refreshes with
# `scope: "openid email offline_access"` hardcoded (tesla_api/auth/refresh.ex) and sends
# `client_id: TESLA_AUTH_CLIENT_ID`. Tesla requires `scope` on /authorize and treats a scoped-down
# refresh as honoured, so the token must be granted at least `vehicle_device_data` — and the client
# id used here must be the same one in tesla-oauth.yaml, or the first refresh dies with
# `invalid_client` (TeslaMate issue #4091). Both are checked below rather than left to a 401 later.
#
# WHERE THE CODE GOES. The authorization code comes back on https://authorize.titan.arrieta.eu/callback,
# which is a Deployment that logs the request line and does nothing else (apps/tesla/auth-callback.yaml).
# This script prints the URL to open, then you paste the logged `code=` back here. The code is never
# exchanged in the cluster: the client secret stays on this machine, and the endpoint stays a logger.
set -euo pipefail

CLIENT_ID=${TESLA_CLIENT_ID:-}
CLIENT_SECRET=${TESLA_CLIENT_SECRET:-}
REDIRECT_URI=${TESLA_REDIRECT_URI:-https://authorize.titan.arrieta.eu/callback}
AUDIENCE=${TESLA_AUDIENCE:-https://fleet-api.prd.eu.vn.cloud.tesla.com}
TOKEN_HOST=${TESLA_TOKEN_HOST:-https://fleet-auth.prd.vn.cloud.tesla.com}
# vehicle_device_data is the one TeslaMate cannot work without; vehicle_location is what makes the
# map and the drives useful; offline_access is what produces the refresh token it refreshes with.
# No *_cmds scope: remote commands are out of scope for v1 (spec §3), and asking for a scope that is
# never used is asking the owner to grant access that nothing needs.
SCOPE=${TESLA_SCOPE:-"openid offline_access user_data vehicle_device_data vehicle_location"}

usage() {
  cat <<'EOF'
usage:
  tesla-auth.sh url            print the consent URL to open in a browser
  tesla-auth.sh exchange CODE  redeem the code from the callback log for a token pair

  TESLA_CLIENT_ID      your application's client id (required; also the one TeslaMate must hold)
  TESLA_CLIENT_SECRET  your application's client secret (required by exchange). Prefer the prompt over
                       the environment: an env var is visible in /proc/<pid>/environ to your own user
                       and is inherited by every child process.
  TESLA_REDIRECT_URI   must match the application's registered redirect exactly
                       (default https://authorize.titan.arrieta.eu/callback)
  TESLA_AUDIENCE       must be the Fleet API base URL for the region your car is in
                       (default the EU one; a EU car against NA does not resolve)
  TESLA_SCOPE          default: openid offline_access user_data vehicle_device_data vehicle_location

The full walk-through is docs/teslamate-runbook.md §5.
EOF
}

url() {
  : "${CLIENT_ID:?TESLA_CLIENT_ID is not set - it is the client id on developer.tesla.com, the same one that goes into tesla-oauth.yaml}"
  # state is NOT secret: it is a CSRF nonce, and the callback runs in a browser we do not control.
  # Random rather than fixed so a replayed redirect from an old tab cannot be confused for this one.
  local state
  state=$(python3 -c 'import secrets;print(secrets.token_urlsafe(16))')
  cat <<EOF
Open this with this Tesla account, approve the scopes, and let it land on the callback:

$(python3 - <<PY
import urllib.parse as u
print("https://auth.tesla.com/oauth2/v3/authorize?" + u.urlencode({
  "response_type": "code",
  "client_id": "$CLIENT_ID",
  "redirect_uri": "$REDIRECT_URI",
  "scope": "$SCOPE",
  "state": "$state",
  "prompt": "login",
  "prompt_missing_scopes": "true",
}))
PY
)

The state this run expects is:

    $state

Then read the code back out of the callback's log, and pass it to:

    tesla-auth.sh exchange '<code>'

The callback logs one line per request, e.g.
    ?code=NA_abc...&state=$state
A line whose state does not match the value above is not yours — do not redeem it.
EOF
}

exchange() {
  local code=${1:-}
  [ -n "$code" ] || { echo "FAIL: pass the code from the callback log"; exit 1; }
  : "${CLIENT_ID:?TESLA_CLIENT_ID is not set}"
  if [ -z "$CLIENT_SECRET" ]; then
    if [ -t 0 ]; then
      read -r -s -p "Client secret: " CLIENT_SECRET </dev/tty; echo >&2
    else
      CLIENT_SECRET=$(cat)
    fi
  fi
  [ -n "$CLIENT_SECRET" ] || { echo "FAIL: no client secret"; exit 1; }
  # The one mistake that costs an hour: a code from a different client id fails as
  # invalid_auth_code/invalid_client, which reads like an expired code.
  case "$code" in
    *[[:space:]]*) echo "FAIL: the code has whitespace in it - truncated paste from the log?"; exit 1 ;;
  esac

  echo "redeeming the code at $TOKEN_HOST ..." >&2
  local resp
  resp=$(curl -sS --fail-with-body --request POST "$TOKEN_HOST/oauth2/v3/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode "code=$code" \
    --data-urlencode "audience=$AUDIENCE" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" 2>&1) || {
      echo "FAIL: the token endpoint refused the exchange. Its own words:"; echo "$resp"
      echo
      echo "invalid_auth_code  -> the code was already used (single use, short lived) or expired: open"
      echo "                      the URL again. A code can only be redeemed once, so a retry needs a"
      echo "                      fresh one."
      echo "invalid_client     -> the secret does not belong to $CLIENT_ID, or the client id here is"
      echo "                      not the one that produced the code."
      echo "redirect_uri       -> $REDIRECT_URI is not byte-for-byte the URI registered on the app."
      exit 1
    }

  python3 - "$resp" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
tok, ref = d.get("access_token"), d.get("refresh_token")
if not tok or not ref:
    sys.exit("FAIL: the response has no access_token/refresh_token pair.\n" + json.dumps(d, indent=2))
# A short access token is not a JWT and carries no scopes to inspect; offline_access is what produces
# a refresh token, so its presence is the direct evidence that the grant included it.
print("\n== token pair (paste into TeslaMate's sign-in page)")
print("\nACCESS TOKEN:\n" + tok)
print("\nREFRESH TOKEN:\n" + ref)
claims = {}
try:
    import base64
    p = tok.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
except Exception:
    pass
if claims:
    aud = claims.get("aud")
    print("\naudience:", aud, "(must be the Fleet API base URL for your region)")
    if isinstance(aud, list):
        aud = aud[0] if aud else ""
    if "fleet-api" not in str(aud):
        print("  WARNING: the audience is not a fleet-api host. TeslaMate's TESLA_API_HOST must match it.")
print("expires_in:", d.get("expires_in"), "seconds; refresh_token expires in ~3 months and is single use.")
print("\nNext: paste both into TeslaMate's sign-in page, then scale the callback back to 0.")
PY
  echo >&2
  echo "The refresh token is single use: every refresh returns a new one, and TeslaMate stores it." >&2
  echo "Do not copy this pair anywhere else, and do not paste it into a chat or an issue." >&2
}

case "${1:-}" in
  url)      shift; url ;;
  exchange) shift; exchange "${1:-}" ;;
  -h|--help|"") usage; exit 0 ;;
  *) usage; exit 1 ;;
esac
