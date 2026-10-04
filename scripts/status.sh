#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

main() {
  local ids id state health name restarts found_problem=0 volumes
  local -a ids_array=()
  require_docker_compose
  assert_pinned_checkout

  log "Compose status"
  compose ps

  ids="$(compose ps -aq)"
  if [[ -z "$ids" ]]; then
    warn "No Sentry containers exist. Run ./scripts/start.sh."
  else
    while IFS= read -r id; do
      [[ -n "$id" ]] && ids_array+=("$id")
    done <<<"$ids"
    for id in "${ids_array[@]}"; do
      state="$(docker inspect --format '{{.State.Status}}' "$id")"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
      name="$(docker inspect --format '{{.Name}}' "$id" | sed 's#^/##')"
      restarts="$(docker inspect --format '{{.RestartCount}}' "$id")"
      if [[ "$state" != "running" || "$health" == "unhealthy" ]]; then
        warn "$name: state=$state health=$health restarts=$restarts"
        found_problem=1
      fi
    done
  fi
  if ((found_problem == 0)); then
    log "No unhealthy or restarting containers detected."
  fi

  if [[ -n "$ids" ]]; then
    log "One-shot Sentry container resource usage"
    # A snapshot only: use observe.sh for the ten-minute idle/post-event record.
    docker stats --no-stream "${ids_array[@]}"

    log "Named volumes attached to Sentry containers"
    volumes="$({
      for id in "${ids_array[@]}"; do
        docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$id"
      done
    } | sed '/^[[:space:]]*$/d' | sort -u)"
    if [[ -n "$volumes" ]]; then
      printf '%s\n' "$volumes"
    else
      warn "No named volumes were found on the current Sentry containers."
    fi
  fi

  log "Docker disk usage"
  docker system df
  log "Host filesystem usage"
  df -h "$ROOT_DIR"
}

main "$@"
