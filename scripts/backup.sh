#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

leave_stopped=0
stack_was_running=0
backup_complete=0

usage() {
  printf 'Usage: %s [--leave-stopped]\n' "$0"
  printf 'Creates a cold, read-only archive of configuration and attached Docker volumes.\n'
}

recover_services() {
  local code=$?
  if ((stack_was_running == 1 && leave_stopped == 0)); then
    if ((backup_complete == 1)); then
      log "Restarting services after backup..."
    else
      warn "Backup did not complete; attempting to restart previously running services."
    fi
    if ! compose up -d; then
      warn "Automatic restart failed; run ./scripts/start.sh manually."
      ((code == 0)) && code=1
    fi
  fi
  exit "$code"
}

main() {
  local timestamp destination backup_abs helper_image ids volume volumes_file tsentry_commit
  local -a configuration_paths=(
    .env .env.example README.md config docs scripts
    vendor/self-hosted/.env vendor/self-hosted/.env.custom
    vendor/self-hosted/sentry vendor/self-hosted/relay vendor/self-hosted/symbolicator
  )
  while (($#)); do
    case "$1" in
    --leave-stopped) leave_stopped=1 ;;
    -h | --help)
      usage
      return 0
      ;;
    *) die "Unknown backup option: $1" ;;
    esac
    shift
  done

  require_docker_compose
  require_command tar
  require_command shasum
  assert_pinned_checkout
  helper_image="${TSENTRY_BACKUP_IMAGE:-alpine:3.22.1}"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  destination="$ROOT_DIR/backups/$timestamp"
  [[ ! -e "$destination" ]] || die "Backup destination already exists: $destination"
  mkdir -p "$destination/volumes"
  backup_abs="$(cd "$destination" && pwd)"
  volumes_file="$destination/volume-names.txt"

  trap recover_services EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ids="$(compose ps -q)"
  if [[ -n "$ids" ]]; then
    stack_was_running=1
    log "Stopping the stack for a consistent cold backup..."
    compose stop
  fi

  tsentry_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'uncommitted')"
  {
    printf 'created_utc=%s\n' "$timestamp"
    printf 'tsentry_git_commit=%s\n' "$tsentry_commit"
    printf 'sentry_self_hosted_version=%s\n' "$SENTRY_SELF_HOSTED_VERSION"
    printf 'compose_profile=%s\n' "$COMPOSE_PROFILES"
    printf 'upstream_commit=%s\n' "$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
    printf 'host_arch=%s\n' "$(uname -m)"
    docker version --format 'docker_server={{.Server.Version}}'
    docker compose version
  } >"$destination/manifest.txt"

  if [[ -f "$ROOT_DIR/runtime/instance-inventory.md" ]]; then
    configuration_paths+=(runtime/instance-inventory.md)
  else
    warn "runtime/instance-inventory.md is missing; the backup will contain only the inventory template."
  fi
  tar -chzf "$destination/configuration.tar.gz" \
    -C "$ROOT_DIR" \
    "${configuration_paths[@]}"

  # Capture every named volume attached to this Compose project. Also include
  # the six external data volumes in case containers have not been recreated.
  {
    printf '%s\n' sentry-data sentry-postgres sentry-redis sentry-kafka sentry-clickhouse sentry-seaweedfs
    ids="$(compose ps -aq)"
    if [[ -n "$ids" ]]; then
      for id in $ids; do
        docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$id"
      done
    fi
  } | sed '/^[[:space:]]*$/d' | sort -u >"$volumes_file"

  log "Archiving Docker volumes read-only with $helper_image..."
  while IFS= read -r volume; do
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
      warn "Volume does not exist; skipping: $volume"
      continue
    fi
    log "Backing up volume: $volume"
    docker run --rm --network none --read-only \
      -v "$volume:/source:ro" \
      -v "$backup_abs:/backup" \
      "$helper_image" \
      tar -czf "/backup/volumes/$volume.tar.gz" -C /source .
  done <"$volumes_file"

  (
    cd "$destination"
    shopt -s nullglob
    checksum_files=(configuration.tar.gz manifest.txt volume-names.txt volumes/*.tar.gz)
    shasum -a 256 "${checksum_files[@]}" >SHA256SUMS
  )

  backup_complete=1
  log "Backup complete: $destination"
  log "It contains secrets and event data; keep it encrypted and access-controlled."
  if ((leave_stopped == 1)); then
    log "Services remain stopped as requested."
  fi
}

main "$@"
