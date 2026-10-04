#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

main() {
  local ids id name policy network container project failures=0 startup="unknown"
  require_docker_compose
  assert_pinned_checkout
  ids="$(compose ps -aq)"
  [[ -n "$ids" ]] || die "No Sentry containers exist. Start Sentry before checking recovery."

  log "Container restart policies"
  for id in $ids; do
    name="$(docker inspect --format '{{.Name}}' "$id" | sed 's#^/##')"
    policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$id")"
    printf '%-60s %s\n' "$name" "$policy"
    if [[ "$policy" != "unless-stopped" ]]; then
      warn "$name does not use the upstream unless-stopped policy."
      failures=$((failures + 1))
    fi
  done

  if command -v orb >/dev/null 2>&1 && [[ "$(docker info --format '{{.OperatingSystem}}')" == "OrbStack" ]]; then
    startup="$(orb config get app.start_at_login 2>/dev/null || printf 'unknown')"
    log "OrbStack app.start_at_login=$startup"
    if [[ "$startup" != "true" ]]; then
      warn "OrbStack will not automatically start after user login."
      failures=$((failures + 1))
    fi
  else
    warn "Verify the Docker runtime's 'start at login' setting manually."
  fi

  log "Sentry network membership"
  for network in $(for id in $ids; do docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$id"; done | sort -u); do
    printf 'network=%s\n' "$network"
    for container in $(docker network inspect --format '{{range .Containers}}{{println .Name}}{{end}}' "$network"); do
      project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || true)"
      if [[ "$project" != "sentry-self-hosted" ]]; then
        warn "Non-Sentry container $container is attached to $network (project=${project:-none})."
        failures=$((failures + 1))
      fi
    done
  done

  if ((failures > 0)); then
    die "Recovery/isolation check found $failures issue(s)."
  fi
  log "Recovery prerequisites and network isolation look correct."
  log "Complete the controlled reboot test in docs/operations.md before declaring reboot recovery verified."
}

main "$@"
