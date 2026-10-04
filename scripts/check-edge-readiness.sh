#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

failures=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '[INFO] %s\n' "$*"; }

main() {
  local hostname local_url headers status ingress_output caddy_container tunnel_container
  if [[ -f "$ENV_FILE" ]]; then
    load_env
  else
    set -a
    # shellcheck disable=SC1090
    source "$ENV_EXAMPLE"
    set +a
    validate_release "$SENTRY_SELF_HOSTED_VERSION"
  fi
  hostname="${SENTRY_SYSTEM_URL_PREFIX#https://}"
  local_url="http://$SENTRY_BIND"
  caddy_container="${TSENTRY_EDGE_CADDY_CONTAINER:-jjs-edge-caddy}"
  tunnel_container="${TSENTRY_EDGE_TUNNEL_CONTAINER:-jjs-edge-cloudflared}"

  printf '# tsentry edge readiness\n'
  printf 'hostname=%s\nlocal_origin=%s\n\n' "$hostname" "$local_url"

  if [[ "$SENTRY_BIND" == 127.0.0.1:* ]]; then
    pass "Sentry remains bound to host loopback: $SENTRY_BIND"
  else
    fail "SENTRY_BIND must use 127.0.0.1, found $SENTRY_BIND"
  fi

  if command -v dig >/dev/null 2>&1 && [[ -n "$(dig +short "$hostname" 2>/dev/null)" ]]; then
    pass "$hostname resolves through public DNS (currently via the existing wildcard)."
  else
    fail "$hostname does not resolve in public DNS."
  fi

  if docker inspect "$tunnel_container" >/dev/null 2>&1; then
    ingress_output="$(docker exec "$tunnel_container" cloudflared --config /etc/cloudflared/config.yml tunnel ingress rule "$SENTRY_SYSTEM_URL_PREFIX" 2>&1 || true)"
    if printf '%s' "$ingress_output" | grep -Fq 'service: http://caddy:80'; then
      pass "Existing Cloudflare Tunnel ingress routes the hostname to edge Caddy."
      printf '%s\n' "$ingress_output" | sed -n '1,5p'
    else
      fail "Existing tunnel ingress does not route this hostname to edge Caddy."
    fi
  else
    fail "Tunnel container not found: $tunnel_container"
  fi

  if docker inspect "$caddy_container" >/dev/null 2>&1; then
    if docker exec "$caddy_container" sh -c 'wget -qO- -T 3 http://host.docker.internal:9000/_health/ >/dev/null' 2>/dev/null; then
      pass "Edge Caddy can reach the loopback-only Sentry origin through host.docker.internal."
    else
      fail "Edge Caddy cannot reach Sentry health at host.docker.internal:9000."
    fi
    if docker exec "$caddy_container" caddy adapt --config /etc/caddy/jjs-edge/Caddyfile --adapter caddyfile 2>/dev/null | grep -Fq "$hostname"; then
      pass "The active Caddy configuration contains the singleton Sentry host route."
    else
      fail "The active Caddy configuration does not yet contain $hostname."
    fi
  else
    fail "Caddy container not found: $caddy_container"
  fi

  headers="$(curl --silent --show-error --max-time 15 -o /dev/null -D - "$SENTRY_SYSTEM_URL_PREFIX/" 2>/dev/null || true)"
  status="$(printf '%s\n' "$headers" | awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }')"
  if printf '%s\n' "$headers" | grep -Eiq 'location: .*cloudflareaccess\.com|location: /cdn-cgi/access|set-cookie: CF_Authorization='; then
    pass "Cloudflare Access challenges unauthenticated requests."
  else
    fail "Cloudflare Access challenge was not detected (current HTTP status: ${status:-none})."
  fi

  note "Caddy route source: $ROOT_DIR/config/caddy/sentry.caddy"
  note "Do not reload edge Caddy until all checks except the active-route check pass."
  if ((failures > 0)); then
    printf 'RESULT=BLOCKED (%s failure(s))\n' "$failures"
    return 1
  fi
  printf 'RESULT=READY\n'
}

main "$@"

