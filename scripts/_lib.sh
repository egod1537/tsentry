#!/usr/bin/env bash

# Shared helpers. Caller scripts enable strict mode.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UPSTREAM_DIR="$ROOT_DIR/vendor/self-hosted"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
# Used by bootstrap after this shared file is sourced.
# shellcheck disable=SC2034
OFFICIAL_REMOTE="https://github.com/getsentry/self-hosted.git"

log() {
  printf '[tsentry] %s\n' "$*"
}

warn() {
  printf '[tsentry] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[tsentry] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_supported_bash() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    die "Bash 4.4+ is required by Sentry self-hosted (found $BASH_VERSION). Install a current Bash and put it first in PATH."
  fi
}

ensure_local_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "Created .env from .env.example. Review it before exposing this service."
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Missing .env. Run: cp .env.example .env"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  : "${SENTRY_SELF_HOSTED_VERSION:?SENTRY_SELF_HOSTED_VERSION is required in .env}"
  : "${SENTRY_BIND:?SENTRY_BIND is required in .env}"
  : "${SENTRY_SYSTEM_URL_PREFIX:?SENTRY_SYSTEM_URL_PREFIX is required in .env}"
  : "${SENTRY_EVENT_RETENTION_DAYS:?SENTRY_EVENT_RETENTION_DAYS is required in .env}"
  : "${COMPOSE_PROFILES:?COMPOSE_PROFILES is required in .env}"

  validate_release "$SENTRY_SELF_HOSTED_VERSION"
  [[ "$COMPOSE_PROFILES" == "errors-only" ]] ||
    die "COMPOSE_PROFILES must remain errors-only for this deployment."
  [[ "$SENTRY_SYSTEM_URL_PREFIX" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] ||
    die "SENTRY_SYSTEM_URL_PREFIX must be an HTTPS origin without a path or trailing slash."
  [[ "$SENTRY_EVENT_RETENTION_DAYS" =~ ^[0-9]+$ ]] ||
    die "SENTRY_EVENT_RETENTION_DAYS must be a positive integer."
  ((SENTRY_EVENT_RETENTION_DAYS > 0)) ||
    die "SENTRY_EVENT_RETENTION_DAYS must be greater than zero."
}

validate_release() {
  local version="$1"
  case "$version" in
  master | main | nightly | latest | "")
    die "Refusing floating or empty Sentry version: ${version:-<empty>}"
    ;;
  esac
  [[ "$version" =~ ^[0-9]{2}\.[0-9]{1,2}\.[0-9]+$ ]] ||
    die "Sentry version must be an explicit release tag (for example 26.9.0): $version"
}

require_docker_compose() {
  require_command docker
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is required (the 'docker compose' command)."
  docker info >/dev/null 2>&1 ||
    die "Docker daemon is not reachable. Start OrbStack/Docker Desktop and try again."
}

verify_official_remote() {
  local remote
  [[ -d "$UPSTREAM_DIR/.git" ]] || die "Upstream checkout is missing. Run scripts/bootstrap.sh."
  remote="$(git -C "$UPSTREAM_DIR" remote get-url origin 2>/dev/null || true)"
  case "$remote" in
  https://github.com/getsentry/self-hosted | https://github.com/getsentry/self-hosted.git | git@github.com:getsentry/self-hosted.git)
    ;;
  *)
    die "vendor/self-hosted origin is not the official getsentry/self-hosted repository: ${remote:-<missing>}"
    ;;
  esac
}

ensure_upstream_env_link() {
  local link="$UPSTREAM_DIR/.env.custom"
  [[ -d "$UPSTREAM_DIR" ]] || die "Upstream checkout is missing. Run scripts/bootstrap.sh."

  if [[ -e "$link" && ! -L "$link" ]]; then
    die "$link already exists as a regular file. Move its values to $ENV_FILE, then remove it."
  fi
  ln -sfn ../../.env "$link"
}

assert_pinned_checkout() {
  local expected actual
  load_env
  verify_official_remote
  expected="$(git -C "$UPSTREAM_DIR" rev-parse "refs/tags/$SENTRY_SELF_HOSTED_VERSION^{}" 2>/dev/null || true)"
  actual="$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$expected" ]] || die "Pinned tag is not present locally. Run scripts/bootstrap.sh."
  [[ "$actual" == "$expected" ]] ||
    die "Upstream checkout does not match $SENTRY_SELF_HOSTED_VERSION. Run scripts/bootstrap.sh."
  ensure_upstream_env_link
}

compose() {
  (
    cd "$UPSTREAM_DIR" || exit 1
    docker compose --env-file .env --env-file .env.custom "$@"
  )
}

release_exists_on_origin() {
  local version="$1"
  git -C "$UPSTREAM_DIR" ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1
}

replace_env_value() {
  local file="$1" key="$2" value="$3" tmp
  tmp="${file}.tmp.$$"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    $0 ~ "^" key "=" { print key "=" value; replaced = 1; next }
    { print }
    END { if (!replaced) print key "=" value }
  ' "$file" >"$tmp"
  if [[ "$file" == "$ENV_FILE" ]]; then
    chmod 600 "$tmp"
  else
    chmod 644 "$tmp"
  fi
  mv "$tmp" "$file"
}

replace_readme_pin() {
  local version="$1" file="$ROOT_DIR/README.md" tmp="${ROOT_DIR}/README.md.tmp.$$"
  awk -v version="$version" '
    /^- 현재 pinned Sentry version:/ {
      print "- 현재 pinned Sentry version: `" version "`"
      next
    }
    { print }
  ' "$file" >"$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$file"
}
