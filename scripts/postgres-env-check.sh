#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Validate or preview the Postgres environment file.

Usage:
  scripts/postgres-env-check.sh ensure-env [--env-file PATH] [--yes]
  scripts/postgres-env-check.sh validate [--env-file PATH]
  scripts/postgres-env-check.sh preview [--env-file PATH]
  scripts/postgres-env-check.sh check [--env-file PATH]
  scripts/postgres-env-check.sh prepare-data-dir [--env-file PATH]
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
postgres_dir="$repo_dir/postgres"
env_file="$repo_dir/postgres/.env"
action="${1:-validate}"
assume_yes=0

if [[ $# -gt 0 ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assume_yes=1
      shift
      ;;
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path"
      env_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

confirm() {
  local prompt="$1"
  local answer

  if (( assume_yes == 1 )); then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    return 1
  fi

  printf '%s [Y/n] ' "$prompt" >&2
  IFS= read -r answer

  case "$answer" in
    ""|y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return 0
  fi

  if command -v od >/dev/null 2>&1; then
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    return 0
  fi

  die "could not generate a random password; install openssl or provide POSTGRES_PASSWORD manually"
}

create_env_file_if_missing() {
  local env_dir example_file

  [[ -f "$env_file" ]] && return 0

  example_file="$postgres_dir/.env.example"
  [[ -f "$example_file" ]] || die "missing env example: $example_file"

  if ! confirm "Missing $env_file. Create it from $example_file and generate missing passwords?"; then
    die "missing env file: $env_file. Copy $example_file to $env_file or rerun with --yes."
  fi

  env_dir="$(dirname -- "$env_file")"
  mkdir -p "$env_dir"
  cp "$example_file" "$env_file"
  chmod 0600 "$env_file"
  printf 'Created %s from %s\n' "$env_file" "$example_file"
}

env_file_value() {
  local name="$1"
  local line key value found=""

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      [[ "$key" == "$name" ]] || continue

      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"

      if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi

      found="$value"
    fi
  done < "$env_file"

  printf '%s\n' "$found"
}

set_env_file_value() {
  local name="$1"
  local value="$2"
  local tmp

  tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
  awk -v key="$name" -v replacement="$name=$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*" key "=" {
      print replacement
      done = 1
      next
    }
    { print }
    END {
      if (done == 0) {
        print replacement
      }
    }
  ' "$env_file" > "$tmp"

  mv "$tmp" "$env_file"
  chmod 0600 "$env_file"
}

ensure_passwords() {
  local password_value password

  password_value="$(env_file_value POSTGRES_PASSWORD)"
  [[ -n "$password_value" ]] && return 0

  if ! confirm "POSTGRES_PASSWORD is missing in $env_file. Generate a random password now?"; then
    die "POSTGRES_PASSWORD is required in $env_file"
  fi

  password="$(generate_secret)"
  set_env_file_value POSTGRES_PASSWORD "$password"
  printf 'Generated POSTGRES_PASSWORD in %s\n' "$env_file"
}

ensure_env_file() {
  create_env_file_if_missing
  ensure_passwords
  chmod 0600 "$env_file"
}

load_env_file() {
  local file="$1"
  local line key value

  [[ -f "$file" ]] || die "missing env file: $file. Copy postgres/.env.example to postgres/.env first."

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"

      if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi

      export "$key=$value"
    fi
  done < "$file"
}

env_value() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"

  printf '%s\n' "$value"
}

require_uint() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an unsigned integer, got '$value'"
}

require_positive_uint() {
  local name="$1"
  local value="$2"

  require_uint "$name" "$value"
  (( value > 0 )) || die "$name must be greater than zero"
}

require_non_empty() {
  local name="$1"
  local value="$2"

  [[ -n "$value" ]] || die "$name cannot be empty"
}

validate_optional_uint() {
  local name="$1"
  local value="${!name:-}"

  [[ -z "$value" ]] && return 0
  require_uint "$name" "$value"
}

validate_optional_positive_uint() {
  local name="$1"
  local value="${!name:-}"

  [[ -z "$value" ]] && return 0
  require_positive_uint "$name" "$value"
}

validate_size_value() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+[kKmMgGtTpP]?[bB]?$ ]] || die "$name must be a size like 512m, 1gb, or 4096"
}

validate_duration_value() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+(ms|s|m|h)?$ ]] || die "$name must be a duration like 30s, 2m, or 1h"
}

validate_port() {
  local value

  value="$(env_value POSTGRES_HOST_PORT 5432)"
  require_uint POSTGRES_HOST_PORT "$value"
  (( value >= 1 && value <= 65535 )) || die "POSTGRES_HOST_PORT must be between 1 and 65535"
}

validate_bind_address() {
  local value

  value="$(env_value POSTGRES_BIND_ADDRESS 127.0.0.1)"
  require_non_empty POSTGRES_BIND_ADDRESS "$value"
}

validate_data_dir() {
  local value

  value="$(env_value POSTGRES_DATA_DIR ./data)"
  require_non_empty POSTGRES_DATA_DIR "$value"
  [[ "$value" != "/" ]] || die "POSTGRES_DATA_DIR cannot be /"
}

validate_reserve_percent() {
  local value

  value="$(env_value POSTGRES_HOST_MEMORY_RESERVE_PERCENT 10)"
  require_uint POSTGRES_HOST_MEMORY_RESERVE_PERCENT "$value"
  (( value < 100 )) || die "POSTGRES_HOST_MEMORY_RESERVE_PERCENT must be less than 100"
}

validate_cidrs() {
  local configured normalized cidr prefix max_prefix

  configured="$(env_value POSTGRES_ALLOWED_CIDRS "10.1.0.0/16")"
  normalized="${configured//,/ }"

  for cidr in $normalized; do
    [[ "$cidr" =~ ^([0-9A-Fa-f:.]+)/([0-9]{1,3})$ ]] || die "invalid CIDR in POSTGRES_ALLOWED_CIDRS: $cidr"
    prefix="${BASH_REMATCH[2]}"
    max_prefix=32
    [[ "$cidr" == *:* ]] && max_prefix=128
    (( prefix <= max_prefix )) || die "invalid CIDR prefix in POSTGRES_ALLOWED_CIDRS: $cidr"
  done
}

validate_env() {
  [[ -n "${POSTGRES_PASSWORD:-}" ]] || die "POSTGRES_PASSWORD is required in $env_file"
  [[ -n "$(env_value POSTGRES_DB db_master)" ]] || die "POSTGRES_DB cannot be empty"
  [[ -n "$(env_value POSTGRES_USER postgres)" ]] || die "POSTGRES_USER cannot be empty"
  [[ -n "$(env_value POSTGRES_IMAGE postgres:18.4-alpine)" ]] || die "POSTGRES_IMAGE cannot be empty"
  [[ -n "$(env_value POSTGRES_CONTAINER_NAME postgres)" ]] || die "POSTGRES_CONTAINER_NAME cannot be empty"

  validate_bind_address
  validate_port
  validate_data_dir
  validate_reserve_percent
  validate_cidrs
  validate_size_value POSTGRES_SHM_SIZE "$(env_value POSTGRES_SHM_SIZE 1gb)"
  validate_size_value POSTGRES_LOG_MAX_SIZE "$(env_value POSTGRES_LOG_MAX_SIZE 100m)"
  validate_duration_value POSTGRES_STOP_GRACE_PERIOD "$(env_value POSTGRES_STOP_GRACE_PERIOD 60s)"

  require_positive_uint POSTGRES_LOG_MAX_FILE "$(env_value POSTGRES_LOG_MAX_FILE 5)"
  require_positive_uint POSTGRES_PIDS_LIMIT "$(env_value POSTGRES_PIDS_LIMIT 4096)"
  validate_optional_positive_uint POSTGRES_MEMORY_MB
  validate_optional_positive_uint POSTGRES_CPU_CORES
  validate_optional_positive_uint POSTGRES_MAX_CONNECTIONS
  validate_optional_positive_uint POSTGRES_AUTOVACUUM_MAX_WORKERS
  validate_optional_positive_uint POSTGRES_MAX_WORKER_PROCESSES
  validate_optional_positive_uint POSTGRES_MAX_PARALLEL_WORKERS
  validate_optional_positive_uint POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER
  validate_optional_uint POSTGRES_LOG_MIN_DURATION_STATEMENT
}

preview_env() {
  printf 'Postgres .env preview:\n'
  printf '  POSTGRES_USER=%s\n' "$(env_value POSTGRES_USER postgres)"
  printf '  POSTGRES_DB=%s\n' "$(env_value POSTGRES_DB db_master)"
  printf '  POSTGRES_BIND_ADDRESS=%s\n' "$(env_value POSTGRES_BIND_ADDRESS 127.0.0.1)"
  printf '  POSTGRES_HOST_PORT=%s\n' "$(env_value POSTGRES_HOST_PORT 5432)"
  printf '  POSTGRES_CONTAINER_NAME=%s\n' "$(env_value POSTGRES_CONTAINER_NAME postgres)"
  printf '  POSTGRES_IMAGE=%s\n' "$(env_value POSTGRES_IMAGE postgres:18.4-alpine)"
  printf '  POSTGRES_DATA_DIR=%s\n' "$(env_value POSTGRES_DATA_DIR ./data)"
  printf '  POSTGRES_SHM_SIZE=%s\n' "$(env_value POSTGRES_SHM_SIZE 1gb)"
  printf '  POSTGRES_PIDS_LIMIT=%s\n' "$(env_value POSTGRES_PIDS_LIMIT 4096)"
  printf '  POSTGRES_STOP_GRACE_PERIOD=%s\n' "$(env_value POSTGRES_STOP_GRACE_PERIOD 60s)"
  printf '  POSTGRES_LOG_MAX_SIZE=%s\n' "$(env_value POSTGRES_LOG_MAX_SIZE 100m)"
  printf '  POSTGRES_LOG_MAX_FILE=%s\n' "$(env_value POSTGRES_LOG_MAX_FILE 5)"
  printf '  POSTGRES_ALLOWED_CIDRS=%s\n' "$(env_value POSTGRES_ALLOWED_CIDRS "10.1.0.0/16")"
  printf '  POSTGRES_MEMORY_MB=%s\n' "$(env_value POSTGRES_MEMORY_MB auto)"
  printf '  POSTGRES_CPU_CORES=%s\n' "$(env_value POSTGRES_CPU_CORES auto)"
  printf '  POSTGRES_HOST_MEMORY_RESERVE_PERCENT=%s\n' "$(env_value POSTGRES_HOST_MEMORY_RESERVE_PERCENT 10)"
}

resolve_compose_path() {
  local path="$1"

  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$postgres_dir" "$path"
  fi
}

prepare_data_dir() {
  local data_dir resolved_dir

  data_dir="$(env_value POSTGRES_DATA_DIR ./data)"
  resolved_dir="$(resolve_compose_path "$data_dir")"

  if [[ -e "$resolved_dir" && ! -d "$resolved_dir" ]]; then
    die "POSTGRES_DATA_DIR exists but is not a directory: $resolved_dir"
  fi

  mkdir -p "$resolved_dir"
  printf 'Postgres data directory is ready: %s\n' "$resolved_dir"
}

case "$action" in
  ensure-env)
    ensure_env_file
    printf 'Postgres .env is ready: %s\n' "$env_file"
    ;;
  validate)
    load_env_file "$env_file"
    validate_env
    printf 'Postgres .env is valid: %s\n' "$env_file"
    ;;
  preview)
    load_env_file "$env_file"
    preview_env
    ;;
  check)
    load_env_file "$env_file"
    validate_env
    printf 'Postgres .env is valid: %s\n' "$env_file"
    preview_env
    ;;
  prepare-data-dir)
    load_env_file "$env_file"
    validate_env
    prepare_data_dir
    ;;
  -h|--help)
    usage
    ;;
  *)
    die "unknown action: $action"
    ;;
esac
