#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

main() {
  local config_file tmp mode
  assert_pinned_checkout
  config_file="$UPSTREAM_DIR/sentry/config.yml"
  [[ -f "$config_file" ]] ||
    die "Generated Sentry config is missing: $config_file. Run bootstrap first."
  tmp="${config_file}.tmp.$$"
  mode="$(stat -f '%Lp' "$config_file" 2>/dev/null || stat -c '%a' "$config_file")"

  awk -v url="$SENTRY_SYSTEM_URL_PREFIX" '
    BEGIN { url_replaced = 0; registration_replaced = 0 }
    /^system\.url-prefix:/ {
      quote = sprintf("%c", 39)
      print "system.url-prefix: " quote url quote
      url_replaced = 1
      next
    }
    /^auth\.allow-registration:/ {
      print "auth.allow-registration: false"
      registration_replaced = 1
      next
    }
    { print }
    END {
      if (!url_replaced) {
        quote = sprintf("%c", 39)
        print ""
        print "# Managed by tsentry/scripts/configure-url.sh"
        print "system.url-prefix: " quote url quote
      }
      if (!registration_replaced) {
        print ""
        print "# Public self-registration is disabled by tsentry policy."
        print "auth.allow-registration: false"
      }
    }
  ' "$config_file" >"$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$config_file"

  if ! grep -Fqx "system.url-prefix: '$SENTRY_SYSTEM_URL_PREFIX'" "$config_file"; then
    die "Failed to set system.url-prefix in generated Sentry config."
  fi
  if ! grep -Fqx "auth.allow-registration: false" "$config_file"; then
    die "Failed to disable public Sentry registration."
  fi
  log "Configured Sentry canonical URL: $SENTRY_SYSTEM_URL_PREFIX"
  log "Disabled public Sentry self-registration."
  log "Restart the stack with ./scripts/start.sh to apply the change."
}

main "$@"
