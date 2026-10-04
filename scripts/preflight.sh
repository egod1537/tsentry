#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

MIN_DOCKER_CPUS=2
MIN_DOCKER_MEMORY_MB=7000
MIN_FREE_FOR_SENTRY_MB=7000
MIN_FREE_DISK_GB=20
WARN_FREE_DISK_GB=40
failures=0
warnings=0

fail_check() {
  printf '[FAIL] %s\n' "$*"
  failures=$((failures + 1))
}

pass_check() {
  printf '[PASS] %s\n' "$*"
}

warn_check() {
  printf '[WARN] %s\n' "$*"
  warnings=$((warnings + 1))
}

version_at_least() {
  local actual="$1" required="$2" a1 a2 a3 r1 r2 r3
  actual="${actual#v}"
  actual="${actual%%-*}"
  required="${required#v}"
  IFS=. read -r a1 a2 a3 <<EOF
$actual
EOF
  IFS=. read -r r1 r2 r3 <<EOF
$required
EOF
  a1="${a1%%[^0-9]*}"; a2="${a2%%[^0-9]*}"; a3="${a3%%[^0-9]*}"
  r1="${r1%%[^0-9]*}"; r2="${r2%%[^0-9]*}"; r3="${r3%%[^0-9]*}"
  a1="${a1:-0}"; a2="${a2:-0}"; a3="${a3:-0}"
  r1="${r1:-0}"; r2="${r2:-0}"; r3="${r3:-0}"
  ((a1 > r1 || (a1 == r1 && a2 > r2) || (a1 == r1 && a2 == r2 && a3 >= r3)))
}

memory_usage_mib() {
  awk '
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
      split($0, pair, " / ")
      number = pair[1]; sub(/[A-Za-z]+$/, "", number)
      unit = pair[1]; sub(/^[0-9.]+/, "", unit)
      total += mib(number + 0, unit)
    }
    END { printf "%.0f", total }
  '
}

main() {
  local timestamp report host_arch host_cpu host_ram_bytes host_ram_gib
  local docker_version compose_version docker_arch docker_cpu docker_mem_bytes docker_mem_mb
  local disk_kb disk_gb running_count non_sentry_ids existing_mem_mb free_for_sentry_mb

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$ROOT_DIR/runtime"
  report="$ROOT_DIR/runtime/preflight-$timestamp.log"
  exec > >(tee "$report") 2>&1

  printf '# tsentry deployment preflight\n'
  printf 'timestamp_utc=%s\n' "$timestamp"
  printf 'report=%s\n\n' "$report"

  host_arch="$(uname -m)"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    host_cpu="$(sysctl -n hw.logicalcpu)"
    host_ram_bytes="$(sysctl -n hw.memsize)"
  else
    host_cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0')"
    host_ram_bytes="$(awk '/MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null || printf '0')"
  fi
  host_ram_gib="$(awk -v bytes="$host_ram_bytes" 'BEGIN { printf "%.1f", bytes / 1024 / 1024 / 1024 }')"

  printf '## Host\n'
  printf 'architecture=%s\nlogical_cpus=%s\nhost_ram_gib=%s\n' "$host_arch" "$host_cpu" "$host_ram_gib"
  df -h "$ROOT_DIR"

  if ! command -v docker >/dev/null 2>&1; then
    fail_check "Docker CLI is not installed."
    printf '\nPreflight blocked with %s failure(s).\n' "$failures"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    fail_check "Docker daemon is not reachable."
    printf '\nPreflight blocked with %s failure(s).\n' "$failures"
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    fail_check "Docker Compose v2 is not available."
    printf '\nPreflight blocked with %s failure(s).\n' "$failures"
    return 1
  fi

  docker_version="$(docker version --format '{{.Server.Version}}')"
  compose_version="$(docker compose version --short)"
  docker_arch="$(docker info --format '{{.Architecture}}')"
  docker_cpu="$(docker info --format '{{.NCPU}}')"
  docker_mem_bytes="$(docker info --format '{{.MemTotal}}')"
  docker_mem_mb=$((docker_mem_bytes / 1024 / 1024))
  disk_kb="$(df -Pk "$ROOT_DIR" | awk 'NR == 2 { print $4 }')"
  disk_gb=$((disk_kb / 1024 / 1024))
  running_count="$(docker ps -q | wc -l | tr -d ' ')"

  non_sentry_ids="$(docker ps --format '{{.ID}} {{.Label "com.docker.compose.project"}}' | awk '$2 != "sentry-self-hosted" { print $1 }')"
  if [[ -n "$non_sentry_ids" ]]; then
    # Intentional word splitting: Docker expects individual container IDs.
    # shellcheck disable=SC2086
    existing_mem_mb="$(docker stats --no-stream --format '{{.MemUsage}}' $non_sentry_ids | memory_usage_mib)"
  else
    existing_mem_mb=0
  fi
  free_for_sentry_mb=$((docker_mem_mb - existing_mem_mb))

  printf '\n## Docker allocation\n'
  printf 'docker_engine=%s\ndocker_compose=%s\ndocker_architecture=%s\n' "$docker_version" "$compose_version" "$docker_arch"
  printf 'docker_cpus=%s\ndocker_memory_mib=%s\n' "$docker_cpu" "$docker_mem_mb"
  printf 'existing_non_sentry_memory_mib=%s\nestimated_free_for_sentry_mib=%s\n' "$existing_mem_mb" "$free_for_sentry_mb"
  printf 'running_containers=%s\nfree_disk_gib=%s\n' "$running_count" "$disk_gb"

  printf '\n## Running container resources\n'
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.BlockIO}}'
  printf '\n## Docker disk usage\n'
  docker system df

  printf '\n## Required checks\n'
  if version_at_least "$BASH_VERSION" 4.4.0; then
    pass_check "Bash $BASH_VERSION >= 4.4.0"
  else
    fail_check "Bash 4.4.0+ is required; current shell is $BASH_VERSION"
  fi
  if version_at_least "$docker_version" 19.03.6; then
    pass_check "Docker $docker_version >= 19.03.6"
  else
    fail_check "Docker $docker_version is below upstream minimum 19.03.6"
  fi
  if version_at_least "$compose_version" 2.32.2; then
    pass_check "Docker Compose $compose_version >= 2.32.2"
  else
    fail_check "Docker Compose $compose_version is below upstream minimum 2.32.2"
  fi
  if ((docker_cpu >= MIN_DOCKER_CPUS)); then
    pass_check "Docker CPUs $docker_cpu >= $MIN_DOCKER_CPUS"
  else
    fail_check "Docker needs at least $MIN_DOCKER_CPUS CPUs; found $docker_cpu"
  fi
  if ((docker_mem_mb >= MIN_DOCKER_MEMORY_MB)); then
    pass_check "Docker memory ${docker_mem_mb} MiB >= upstream errors-only minimum ${MIN_DOCKER_MEMORY_MB} MB"
  else
    fail_check "Docker memory ${docker_mem_mb} MiB is below upstream errors-only minimum ${MIN_DOCKER_MEMORY_MB} MB"
  fi
  if ((free_for_sentry_mb >= MIN_FREE_FOR_SENTRY_MB)); then
    pass_check "Estimated Docker headroom ${free_for_sentry_mb} MiB can accommodate Sentry's ${MIN_FREE_FOR_SENTRY_MB} MB minimum"
  else
    fail_check "Only ${free_for_sentry_mb} MiB remains after existing containers; require ${MIN_FREE_FOR_SENTRY_MB} MB to protect co-located services"
  fi
  if ((disk_gb >= MIN_FREE_DISK_GB)); then
    pass_check "Free disk ${disk_gb} GiB >= official recommended floor ${MIN_FREE_DISK_GB} GB"
  else
    fail_check "Free disk ${disk_gb} GiB is below the official recommended ${MIN_FREE_DISK_GB} GB"
  fi
  if ((disk_gb < WARN_FREE_DISK_GB)); then
    warn_check "Free disk is below ${WARN_FREE_DISK_GB} GiB; installation plus cold backups have little operating margin"
  fi
  if lsof -nP -iTCP:9000 -sTCP:LISTEN >/dev/null 2>&1 ||
    docker ps --format '{{.Ports}}' | awk '/9000->/ { found = 1 } END { exit !found }'; then
    fail_check "TCP port 9000 is already in use"
  else
    pass_check "TCP port 9000 is available"
  fi

  printf '\nsummary_failures=%s\nsummary_warnings=%s\n' "$failures" "$warnings"
  if ((failures > 0)); then
    printf 'RESULT=BLOCKED. Do not run the Sentry installer until every failure is resolved.\n'
    return 1
  fi
  printf 'RESULT=PASS. The official installer will repeat its own minimum checks.\n'
}

main "$@"
