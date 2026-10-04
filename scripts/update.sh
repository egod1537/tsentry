#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

usage() {
  printf 'Usage: %s <target-release> --ack-release-notes\n' "$0"
  printf 'Example: %s 26.10.0 --ack-release-notes\n' "$0"
}

main() {
  local target="" acknowledged=0 current
  while (($#)); do
    case "$1" in
    --ack-release-notes) acknowledged=1 ;;
    -h | --help)
      usage
      return 0
      ;;
    -*) die "Unknown update option: $1" ;;
    *)
      [[ -z "$target" ]] || die "Only one target release may be specified."
      target="$1"
      ;;
    esac
    shift
  done

  [[ -n "$target" ]] || {
    usage
    die "A specific target release is required; latest is never selected automatically."
  }
  validate_release "$target"
  if ((acknowledged == 0)); then
    printf 'Review the target release notes first:\n'
    printf '  https://github.com/getsentry/self-hosted/releases/tag/%s\n' "$target"
    printf 'Also check every intervening release for mandatory hard-stop upgrades.\n'
    die "Re-run with --ack-release-notes only after completing that review."
  fi

  require_command git
  require_supported_bash
  require_docker_compose
  assert_pinned_checkout
  current="$SENTRY_SELF_HOSTED_VERSION"
  [[ "$target" != "$current" ]] || die "Already pinned to $target."
  if [[ -n "$(git -C "$UPSTREAM_DIR" status --short --untracked-files=no)" ]]; then
    die "Upstream checkout has tracked modifications; update will not overwrite them."
  fi
  release_exists_on_origin "$target" ||
    die "Release tag $target does not exist on the official origin."

  log "Upgrade plan: $current -> $target"
  log "Creating a cold backup before changing the checkout..."
  "$SCRIPT_DIR/backup.sh" --leave-stopped

  log "Fetching and checking out $target..."
  git -C "$UPSTREAM_DIR" fetch --force origin "refs/tags/$target:refs/tags/$target"
  git -C "$UPSTREAM_DIR" checkout --detach "refs/tags/$target"
  replace_env_value "$ENV_FILE" SENTRY_SELF_HOSTED_VERSION "$target"
  replace_env_value "$ENV_EXAMPLE" SENTRY_SELF_HOSTED_VERSION "$target"
  replace_readme_pin "$target"
  ensure_upstream_env_link

  log "Running the official installer for $target..."
  (
    cd "$UPSTREAM_DIR"
    ./install.sh --skip-user-creation --no-report-self-hosted-issues --apply-automatic-config-updates
  )
  "$SCRIPT_DIR/configure-url.sh"

  log "Upgrade installation completed. Services remain stopped for inspection."
  log "Review git diff, then start with ./scripts/start.sh"
}

main "$@"
