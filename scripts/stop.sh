#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

main() {
  require_docker_compose
  assert_pinned_checkout
  log "Stopping Sentry containers. Persistent volumes will not be removed."
  compose down
  log "Stopped. No volumes were deleted."
}

main "$@"
