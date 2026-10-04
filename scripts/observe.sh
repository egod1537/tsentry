#!/usr/bin/env bash
# printf format strings intentionally use single quotes around Markdown backticks.
# shellcheck disable=SC2016
set -Eeuo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

usage() {
  printf 'Usage: %s idle [--duration 600]\n' "$0"
  printf '       %s post-events [--duration 0]\n' "$0"
}

main() {
  local mode="${1:-}" duration="" timestamp report ids count raw parsed
  local total_mem total_cpu top_name top_mem top_cpu
  if [[ "$mode" == "-h" || "$mode" == "--help" ]]; then
    usage
    return 0
  fi
  [[ "$mode" == "idle" || "$mode" == "post-events" ]] || {
    usage
    die "Observation mode must be idle or post-events."
  }
  shift
  while (($#)); do
    case "$1" in
    --duration)
      shift
      (($#)) || die "--duration requires seconds."
      duration="$1"
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *) die "Unknown observation option: $1" ;;
    esac
    shift
  done
  if [[ -z "$duration" ]]; then
    if [[ "$mode" == "idle" ]]; then duration=600; else duration=0; fi
  fi
  [[ "$duration" =~ ^[0-9]+$ ]] || die "Duration must be an integer number of seconds."
  if [[ "$mode" == "idle" && "$duration" -lt 600 ]]; then
    die "Idle observation must run for at least 600 seconds."
  fi

  require_docker_compose
  assert_pinned_checkout
  ids="$(compose ps -q)"
  [[ -n "$ids" ]] || die "No running Sentry containers. Start the stack first."

  log "Observation mode=$mode; waiting ${duration}s before snapshot..."
  if ((duration > 0)); then sleep "$duration"; fi

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$ROOT_DIR/runtime/observations"
  report="$ROOT_DIR/runtime/observations/$timestamp-$mode.md"
  raw="$ROOT_DIR/runtime/observations/.stats.$$.raw"
  parsed="$ROOT_DIR/runtime/observations/.stats.$$.parsed"
  trap 'rm -f "$raw" "$parsed"' EXIT

  # Intentional word splitting: Docker expects individual container IDs.
  # shellcheck disable=SC2086
  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.BlockIO}}' $ids >"$raw"
  awk -F '|' '
    function mib(value, unit) {
      if (unit == "KiB") return value / 1024
      if (unit == "MiB") return value
      if (unit == "GiB") return value * 1024
      if (unit == "kB") return value / 1024
      if (unit == "MB") return value
      if (unit == "GB") return value * 1024
      return 0
    }
    {
      cpu = $2; sub(/%$/, "", cpu)
      split($3, pair, " / ")
      number = pair[1]; sub(/[A-Za-z]+$/, "", number)
      unit = pair[1]; sub(/^[0-9.]+/, "", unit)
      printf "%s|%.2f|%.2f|%s\n", $1, mib(number + 0, unit), cpu + 0, $4
    }
  ' "$raw" >"$parsed"

  count="$(wc -l <"$parsed" | tr -d ' ')"
  total_mem="$(awk -F '|' '{ total += $2 } END { printf "%.1f", total }' "$parsed")"
  total_cpu="$(awk -F '|' '{ total += $3 } END { printf "%.2f", total }' "$parsed")"
  IFS='|' read -r top_name top_mem top_cpu _ <<EOF
$(sort -t '|' -k2,2nr "$parsed" | head -1)
EOF

  {
    printf '# Sentry resource observation: %s\n\n' "$mode"
    printf -- '- Timestamp (UTC): `%s`\n' "$timestamp"
    printf -- '- Observation delay: `%s seconds`\n' "$duration"
    printf -- '- Sentry version/profile: `%s` / `%s`\n' "$SENTRY_SELF_HOSTED_VERSION" "$COMPOSE_PROFILES"
    printf -- '- Container count: `%s`\n' "$count"
    printf -- '- Aggregate snapshot RAM: `%s MiB`\n' "$total_mem"
    printf -- '- Aggregate snapshot CPU: `%s%%`\n' "$total_cpu"
    printf -- '- Highest-memory container: `%s` (`%s MiB`, `%s%%` CPU)\n\n' "$top_name" "$top_mem" "$top_cpu"
    printf '## Container snapshot\n\n'
    printf '| Container | RAM MiB | CPU %% | Block I/O |\n'
    printf '|---|---:|---:|---|\n'
    awk -F '|' '{ printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }' "$parsed"
    printf '\n## Disk snapshot\n\n```text\n'
    docker system df
    printf '\nSentry volumes:\n'
    docker volume ls --format '{{.Name}}' | awk '/^sentry-/ { print }'
    printf '\nHost filesystem:\n'
    df -h "$ROOT_DIR"
    printf '```\n'
  } >"$report"

  log "Observation written to: $report"
  log "Summary: containers=$count RAM=${total_mem}MiB CPU=${total_cpu}% top=$top_name(${top_mem}MiB)"
}

main "$@"
