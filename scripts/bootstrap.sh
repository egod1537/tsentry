#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

on_error() {
  local code=$?
  printf '[tsentry] ERROR: bootstrap failed at line %s (exit %s).\n' "${BASH_LINENO[0]}" "$code" >&2
  printf '[tsentry] Check Docker runtime resources, network access, and the error immediately above.\n' >&2
  exit "$code"
}
trap on_error ERR

main() {
  "$SCRIPT_DIR/preflight.sh"
  require_command git
  require_command awk
  require_supported_bash
  require_docker_compose
  ensure_local_env
  load_env

  if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
    if [[ -e "$UPSTREAM_DIR" ]]; then
      die "$UPSTREAM_DIR exists but is not a Git checkout. Move it aside and retry."
    fi
    log "Cloning official getsentry/self-hosted repository..."
    git clone --filter=blob:none --no-checkout "$OFFICIAL_REMOTE" "$UPSTREAM_DIR"
  fi

  verify_official_remote
  if [[ -n "$(git -C "$UPSTREAM_DIR" status --short --untracked-files=no)" ]]; then
    die "Upstream checkout has tracked modifications. Preserve or revert them before bootstrap."
  fi
  release_exists_on_origin "$SENTRY_SELF_HOSTED_VERSION" ||
    die "Release tag $SENTRY_SELF_HOSTED_VERSION does not exist on the official origin."

  log "Fetching official release tags, then selecting $SENTRY_SELF_HOSTED_VERSION..."
  git -C "$UPSTREAM_DIR" fetch --force --tags --prune origin
  git -C "$UPSTREAM_DIR" checkout --detach "refs/tags/$SENTRY_SELF_HOSTED_VERSION"
  ensure_upstream_env_link

  log "Installing Sentry self-hosted $SENTRY_SELF_HOSTED_VERSION ($COMPOSE_PROFILES)."
  log "The upstream installer may download several large container images."
  (
    cd "$UPSTREAM_DIR"
    ./install.sh --skip-user-creation --no-report-self-hosted-issues --apply-automatic-config-updates
  )
  "$SCRIPT_DIR/configure-url.sh"

  log "Bootstrap complete. Start Sentry with: ./scripts/start.sh"
  log "Create the administrator afterward with: cd vendor/self-hosted && ./sentry-admin.sh createuser --superuser"
}

main "$@"
