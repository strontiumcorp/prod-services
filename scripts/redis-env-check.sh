#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Validate, preview, or prepare Redis service inputs.

Usage:
  scripts/redis-env-check.sh ensure-env [--env-file PATH] [--yes]
  scripts/redis-env-check.sh validate [--env-file PATH]
  scripts/redis-env-check.sh preview [--env-file PATH]
  scripts/redis-env-check.sh check [--env-file PATH]
  scripts/redis-env-check.sh prepare-data-dirs [--env-file PATH]
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=shared/common.sh
source "$script_dir/shared/common.sh"

redis_dir="$repo_dir/redis"
env_file="$redis_dir/.env"
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

create_env_file_if_missing() {
  local env_dir example_file

  [[ -f "$env_file" ]] && return 0

  example_file="$redis_dir/.env.example"
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

ensure_passwords() {
  local password_names missing name password value

  password_names="REDIS_CACHE_PASSWORD REDIS_SESSION_PASSWORD REDIS_QUEUE_PASSWORD REDIS_WS_PASSWORD"
  missing=()

  for name in $password_names; do
    value="$(env_file_value "$name")"
    [[ -n "$value" ]] || missing+=("$name")
  done

  (( ${#missing[@]} == 0 )) && return 0

  if ! confirm "Missing Redis password values in $env_file: ${missing[*]}. Generate random passwords now?"; then
    die "Redis passwords are required in $env_file"
  fi

  for name in "${missing[@]}"; do
    password="$(generate_secret)"
    set_env_file_value "$name" "$password"
    printf 'Generated %s in %s\n' "$name" "$env_file"
  done
}

ensure_env_file() {
  create_env_file_if_missing
  ensure_passwords
  chmod 0600 "$env_file"
}

require_password() {
  local name="$1"
  local value="${!name:-}"

  require_non_empty "$name" "$value"
  [[ ! "$value" =~ [[:space:]#] ]] || die "$name cannot contain whitespace or #"
}

validate_port() {
  local name="$1"
  local value

  value="$(env_value "$name" "$2")"
  require_uint "$name" "$value"
  (( value >= 1 && value <= 65535 )) || die "$name must be between 1 and 65535"
}

validate_data_dir() {
  local name="$1"
  local default="$2"
  local value

  value="$(env_value "$name" "$default")"
  require_non_empty "$name" "$value"
  [[ "$value" != "/" ]] || die "$name cannot be /"
}

validate_env() {
  require_non_empty REDIS_IMAGE "$(env_value REDIS_IMAGE redis:8.8.0-alpine)"
  require_non_empty REDIS_BIND_ADDRESS "$(env_value REDIS_BIND_ADDRESS 127.0.0.1)"

  require_non_empty REDIS_CACHE_CONTAINER_NAME "$(env_value REDIS_CACHE_CONTAINER_NAME redis-cache)"
  require_non_empty REDIS_SESSION_CONTAINER_NAME "$(env_value REDIS_SESSION_CONTAINER_NAME redis-session)"
  require_non_empty REDIS_QUEUE_CONTAINER_NAME "$(env_value REDIS_QUEUE_CONTAINER_NAME redis-queue)"
  require_non_empty REDIS_WS_CONTAINER_NAME "$(env_value REDIS_WS_CONTAINER_NAME redis-ws)"

  require_password REDIS_CACHE_PASSWORD
  require_password REDIS_SESSION_PASSWORD
  require_password REDIS_QUEUE_PASSWORD
  require_password REDIS_WS_PASSWORD

  validate_port REDIS_CACHE_HOST_PORT 6379
  validate_port REDIS_SESSION_HOST_PORT 6380
  validate_port REDIS_QUEUE_HOST_PORT 6381
  validate_port REDIS_WS_HOST_PORT 6382

  validate_data_dir REDIS_CACHE_DATA_DIR ./data/cache
  validate_data_dir REDIS_SESSION_DATA_DIR ./data/session
  validate_data_dir REDIS_QUEUE_DATA_DIR ./data/queue
  validate_data_dir REDIS_WS_DATA_DIR ./data/ws

  validate_duration_value REDIS_STOP_GRACE_PERIOD "$(env_value REDIS_STOP_GRACE_PERIOD 30s)"
  validate_size_value REDIS_LOG_MAX_SIZE "$(env_value REDIS_LOG_MAX_SIZE 100m)"
  require_positive_uint REDIS_LOG_MAX_FILE "$(env_value REDIS_LOG_MAX_FILE 5)"
  require_positive_uint REDIS_PIDS_LIMIT "$(env_value REDIS_PIDS_LIMIT 4096)"

  validate_optional_positive_uint REDIS_MEMORY_MB
  validate_optional_positive_uint REDIS_CPU_CORES
  validate_optional_positive_uint REDIS_HOST_MEMORY_RESERVE_PERCENT
  validate_optional_positive_uint REDIS_MEMORY_BUDGET_PERCENT
  validate_optional_positive_uint REDIS_CONTAINER_MEMORY_OVERHEAD_PERCENT
  validate_optional_positive_uint REDIS_QUEUE_CONTAINER_MEMORY_OVERHEAD_PERCENT

  validate_optional_positive_uint REDIS_CACHE_MAXMEMORY_MB
  validate_optional_positive_uint REDIS_SESSION_MAXMEMORY_MB
  validate_optional_positive_uint REDIS_QUEUE_MAXMEMORY_MB
  validate_optional_positive_uint REDIS_WS_MAXMEMORY_MB
  validate_optional_positive_uint REDIS_CACHE_MEM_LIMIT_MB
  validate_optional_positive_uint REDIS_SESSION_MEM_LIMIT_MB
  validate_optional_positive_uint REDIS_QUEUE_MEM_LIMIT_MB
  validate_optional_positive_uint REDIS_WS_MEM_LIMIT_MB
}

preview_env() {
  printf 'Redis .env preview:\n'
  printf '  REDIS_IMAGE=%s\n' "$(env_value REDIS_IMAGE redis:8.8.0-alpine)"
  printf '  REDIS_BIND_ADDRESS=%s\n' "$(env_value REDIS_BIND_ADDRESS 127.0.0.1)"
  printf '  REDIS_CACHE_HOST_PORT=%s\n' "$(env_value REDIS_CACHE_HOST_PORT 6379)"
  printf '  REDIS_SESSION_HOST_PORT=%s\n' "$(env_value REDIS_SESSION_HOST_PORT 6380)"
  printf '  REDIS_QUEUE_HOST_PORT=%s\n' "$(env_value REDIS_QUEUE_HOST_PORT 6381)"
  printf '  REDIS_WS_HOST_PORT=%s\n' "$(env_value REDIS_WS_HOST_PORT 6382)"
  printf '  REDIS_CACHE_CONTAINER_NAME=%s\n' "$(env_value REDIS_CACHE_CONTAINER_NAME redis-cache)"
  printf '  REDIS_SESSION_CONTAINER_NAME=%s\n' "$(env_value REDIS_SESSION_CONTAINER_NAME redis-session)"
  printf '  REDIS_QUEUE_CONTAINER_NAME=%s\n' "$(env_value REDIS_QUEUE_CONTAINER_NAME redis-queue)"
  printf '  REDIS_WS_CONTAINER_NAME=%s\n' "$(env_value REDIS_WS_CONTAINER_NAME redis-ws)"
  printf '  REDIS_CACHE_DATA_DIR=%s\n' "$(env_value REDIS_CACHE_DATA_DIR ./data/cache)"
  printf '  REDIS_SESSION_DATA_DIR=%s\n' "$(env_value REDIS_SESSION_DATA_DIR ./data/session)"
  printf '  REDIS_QUEUE_DATA_DIR=%s\n' "$(env_value REDIS_QUEUE_DATA_DIR ./data/queue)"
  printf '  REDIS_WS_DATA_DIR=%s\n' "$(env_value REDIS_WS_DATA_DIR ./data/ws)"
  printf '  REDIS_MEMORY_MB=%s\n' "$(env_value REDIS_MEMORY_MB auto)"
  printf '  REDIS_CPU_CORES=%s\n' "$(env_value REDIS_CPU_CORES auto)"
  printf '  REDIS_HOST_MEMORY_RESERVE_PERCENT=%s\n' "$(env_value REDIS_HOST_MEMORY_RESERVE_PERCENT 10)"
  printf '  REDIS_MEMORY_BUDGET_PERCENT=%s\n' "$(env_value REDIS_MEMORY_BUDGET_PERCENT 25)"
  printf '  REDIS_STOP_GRACE_PERIOD=%s\n' "$(env_value REDIS_STOP_GRACE_PERIOD 30s)"
  printf '  REDIS_LOG_MAX_SIZE=%s\n' "$(env_value REDIS_LOG_MAX_SIZE 100m)"
  printf '  REDIS_LOG_MAX_FILE=%s\n' "$(env_value REDIS_LOG_MAX_FILE 5)"
  printf '  REDIS_PIDS_LIMIT=%s\n' "$(env_value REDIS_PIDS_LIMIT 4096)"
}

resolve_compose_path() {
  local path="$1"

  resolve_path_relative_to "$redis_dir" "$path"
}

prepare_one_data_dir() {
  local name="$1"
  local default="$2"
  local value resolved_dir

  value="$(env_value "$name" "$default")"
  resolved_dir="$(resolve_compose_path "$value")"

  if [[ -e "$resolved_dir" && ! -d "$resolved_dir" ]]; then
    die "$name exists but is not a directory: $resolved_dir"
  fi

  mkdir -p "$resolved_dir"
  printf 'Redis data directory is ready: %s\n' "$resolved_dir"
}

prepare_data_dirs() {
  prepare_one_data_dir REDIS_CACHE_DATA_DIR ./data/cache
  prepare_one_data_dir REDIS_SESSION_DATA_DIR ./data/session
  prepare_one_data_dir REDIS_QUEUE_DATA_DIR ./data/queue
  prepare_one_data_dir REDIS_WS_DATA_DIR ./data/ws
}

case "$action" in
  ensure-env)
    ensure_env_file
    printf 'Redis .env is ready: %s\n' "$env_file"
    ;;
  validate)
    load_required_env_file "$env_file" "missing env file: $env_file. Copy redis/.env.example to redis/.env first."
    validate_env
    printf 'Redis .env is valid: %s\n' "$env_file"
    ;;
  preview)
    load_required_env_file "$env_file" "missing env file: $env_file. Copy redis/.env.example to redis/.env first."
    preview_env
    ;;
  check)
    load_required_env_file "$env_file" "missing env file: $env_file. Copy redis/.env.example to redis/.env first."
    validate_env
    printf 'Redis .env is valid: %s\n' "$env_file"
    preview_env
    ;;
  prepare-data-dirs)
    load_required_env_file "$env_file" "missing env file: $env_file. Copy redis/.env.example to redis/.env first."
    validate_env
    prepare_data_dirs
    ;;
  -h|--help)
    usage
    ;;
  *)
    die "unknown action: $action"
    ;;
esac
