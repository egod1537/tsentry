#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

main() {
  local curl_args body headers ingest_headers ingest_status status config_file access_headers="" hostname
  require_command curl
  load_env
  hostname="${SENTRY_SYSTEM_URL_PREFIX#https://}"
  [[ "$SENTRY_BIND" == 127.0.0.1:* ]] || die "Refusing smoke test: Sentry is not loopback-bound."
  config_file="$UPSTREAM_DIR/sentry/config.yml"
  grep -Fqx "system.url-prefix: '$SENTRY_SYSTEM_URL_PREFIX'" "$config_file" ||
    die "Sentry canonical URL is not configured. Run scripts/configure-url.sh."

  curl --fail --silent --show-error --max-time 10 "http://$SENTRY_BIND/_health/" >/dev/null ||
    die "Local Sentry health check failed."
  log "Local Sentry health is OK."

  curl_args=(--silent --show-error --max-time 20 --location --max-redirs 5)
  if [[ -n "${CF_ACCESS_CLIENT_ID:-}" && -n "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    access_headers="$(mktemp /tmp/tsentry-access-headers.XXXXXX)"
    chmod 600 "$access_headers"
    printf 'CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s\n' \
      "$CF_ACCESS_CLIENT_ID" "$CF_ACCESS_CLIENT_SECRET" >"$access_headers"
    curl_args+=(--header "@$access_headers")
    log "Using Cloudflare Access service-token variables (values will not be printed)."
  else
    log "No Access service token supplied; validating the unauthenticated Access gate only."
  fi

  body="$(mktemp /tmp/tsentry-smoke-body.XXXXXX)"
  headers="$(mktemp /tmp/tsentry-smoke-headers.XXXXXX)"
  ingest_headers="$(mktemp /tmp/tsentry-smoke-ingest-headers.XXXXXX)"
  trap 'rm -f "$body" "$headers" "$ingest_headers" ${access_headers:+"$access_headers"}' EXIT INT TERM
  # Temporary files contain only the public login response and headers.
  status="$(curl "${curl_args[@]}" --output "$body" --dump-header "$headers" --write-out '%{http_code}' "$SENTRY_SYSTEM_URL_PREFIX/")"

  if [[ -z "${CF_ACCESS_CLIENT_ID:-}" ]]; then
    grep -Eiq 'cloudflareaccess\.com|/cdn-cgi/access' "$headers" "$body" ||
      die "Cloudflare Access gate was not observed (HTTP $status)."
    log "Cloudflare Access gate is active; TLS request completed with HTTP $status."

    ingest_status="$(curl --silent --show-error --max-time 20 --request OPTIONS \
      --output /dev/null --dump-header "$ingest_headers" --write-out '%{http_code}' \
      "$SENTRY_SYSTEM_URL_PREFIX/api/1/envelope/")"
    if grep -Eiq 'cloudflareaccess\.com|/cdn-cgi/access' "$ingest_headers"; then
      die "SDK envelope path is still behind interactive Access authentication."
    fi
    [[ ! "$ingest_status" =~ ^5 ]] || die "SDK envelope path returned HTTP $ingest_status."
    log "SDK envelope path bypasses interactive Access as intended (HTTP $ingest_status)."
  else
    [[ "$status" =~ ^(200|302)$ ]] || die "External Sentry returned HTTP $status through Access."
    if grep -Fq "http://$hostname" "$body" "$headers" ||
      grep -Eiq 'http://127\.0\.0\.1:9000|http://localhost:9000' "$body" "$headers"; then
      die "External response contains an insecure or localhost Sentry URL."
    fi
    log "External response passed TLS/canonical-URL checks (HTTP $status)."
  fi

  log "Complete browser login, mixed-content, DSN, and artifact upload checks from docs/external-access.md."
}

main "$@"
