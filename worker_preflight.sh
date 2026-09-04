#!/bin/sh
# agent-watch — worker_preflight.sh
#
# Classify the transport layer BEFORE a worker runs, so the agent never has to
# infer "auth failure" from a tool's wording. Reports one of four states.
#
# Design rules:
#   1. The transport probes run with NO credential in the child environment.
#      A sandbox that cannot resolve DNS and a bad token produce very different
#      states, and re-injecting a known-good token before proving reachability
#      both hides that difference and widens the set of processes that can read
#      the token.
#   2. The auth probe runs only after transport is proven, and only if asked.
#   3. Nothing prints an environment value. States are printed, secrets are not.
#
# Usage:
#   ./worker_preflight.sh                  # transport only
#   ./worker_preflight.sh --auth           # transport, then gh auth if reachable
#   ./worker_preflight.sh --host example.com --api https://example.com/health
#
# Exit codes:
#   0 NET_OK | 0 AUTH_OK
#   3 NET_DISABLED
#   4 API_UNAVAILABLE
#   5 AUTH_FAILED
#   2 usage / missing tool

set -u

HOST="github.com"
API="https://api.github.com/rate_limit"
CHECK_AUTH=0
TIMEOUT="${PREFLIGHT_TIMEOUT:-8}"

while [ $# -gt 0 ]; do
  case "$1" in
    --auth) CHECK_AUTH=1; shift ;;
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --api)  API="${2:?--api needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "PREFLIGHT_ERROR curl not found"; exit 2; }

# --- 1. DNS / transport ------------------------------------------------------
# Run with the credential variables cleared in the child only. The parent
# environment is untouched, and nothing is printed from it.
dns_rc=0
env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_API_TOKEN \
    curl -sS --max-time "$TIMEOUT" -o /dev/null "https://$HOST" 2>/tmp/.pf_err.$$ || dns_rc=$?

if [ "$dns_rc" -ne 0 ]; then
  reason=$(sed -n '1p' /tmp/.pf_err.$$ 2>/dev/null | tr -d '\r')
  rm -f /tmp/.pf_err.$$
  case "$reason" in
    *"Could not resolve"*|*"Resolving timed out"*|*"resolve host"*)
      echo "NET_DISABLED dns=$HOST reason=resolve_failed"
      echo "  the sandbox cannot resolve DNS. this is not an auth problem."
      echo "  codex: add -c sandbox_workspace_write.network_access=true"
      exit 3 ;;
    *)
      echo "NET_DISABLED dns=$HOST reason=transport_failed rc=$dns_rc"
      echo "  ${reason:-no error text}"
      exit 3 ;;
  esac
fi
rm -f /tmp/.pf_err.$$

# --- 2. API endpoint reachable? ---------------------------------------------
# curl already writes 000 on transport failure; do not append a second value.
code=$(env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_API_TOKEN \
       curl -sS --max-time "$TIMEOUT" -o /dev/null -w '%{http_code}' "$API" 2>/dev/null)
[ -n "$code" ] || code=000

case "$code" in
  000)
    echo "API_UNAVAILABLE api=$API http=000"
    echo "  https works for $HOST but the api endpoint did not answer."
    echo "  a proxy allowlist that omits this host looks exactly like this."
    exit 4 ;;
  5*)
    echo "API_UNAVAILABLE api=$API http=$code"
    echo "  endpoint answered with a server error. not a credential problem."
    exit 4 ;;
esac

echo "NET_OK dns=$HOST api=$API http=$code"

# --- 3. Auth, only after transport is proven --------------------------------
if [ "$CHECK_AUTH" -eq 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "AUTH_SKIPPED gh not installed"
    exit 0
  fi
  if login=$(gh api user --jq .login 2>/dev/null) && [ -n "$login" ]; then
    echo "AUTH_OK user=$login"
    exit 0
  fi
  echo "AUTH_FAILED transport=ok"
  echo "  transport is proven, so this is a credential problem and only now"
  echo "  is that a safe conclusion to draw."
  exit 5
fi

exit 0
