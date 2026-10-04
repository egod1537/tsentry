#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

health_url() {
  local bind="$SENTRY_BIND"
  if [[ "$bind" =~ ^[0-9]+$ ]]; then
    printf 'http://127.0.0.1:%s/_health/' "$bind"
  elif [[ "$bind" == 0.0.0.0:* ]]; then
    printf 'http://127.0.0.1:%s/_health/' "${bind##*:}"
  else
    printf 'http://%s/_health/' "$bind"
  fi
}

main() {
  require_docker_compose
  require_command curl
  assert_pinned_checkout

  log "Starting Sentry $SENTRY_SELF_HOSTED_VERSION with profile $COMPOSE_PROFILES..."
  compose up -d --wait --wait-timeout "${TSENTRY_WAIT_TIMEOUT_SECONDS:-600}"
  compose ps

  local url attempt max_attempts
  url="$(health_url)"
  max_attempts="${TSENTRY_HEALTH_ATTEMPTS:-60}"
  log "Waiting for web health endpoint: $url"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if curl --fail --silent --show-error --max-time 5 "$url" >/dev/null 2>&1; then
      log "Sentry is healthy: ${url%/_health/}/"
      exit 0
    fi
    sleep 5
  done

  compose ps
  die "Sentry health check did not pass after $((max_attempts * 5)) seconds. Run ./scripts/status.sh and inspect 'docker compose logs'."
}

main "$@"
