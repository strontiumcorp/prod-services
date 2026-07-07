#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate Redis config files and generated Compose env from templates.

Usage:
  scripts/generate-redis-config.sh [--env-file PATH] [--output-dir PATH]

Defaults:
  --env-file   redis/.env
  --output-dir redis/redis_config

Required in redis/.env:
  REDIS_CACHE_PASSWORD
  REDIS_SESSION_PASSWORD
  REDIS_QUEUE_PASSWORD
  REDIS_WS_PASSWORD

Useful tuning overrides:
  REDIS_MEMORY_MB
  REDIS_CPU_CORES
  REDIS_HOST_MEMORY_RESERVE_PERCENT
  REDIS_MEMORY_BUDGET_PERCENT
  REDIS_CACHE_MAXMEMORY_MB
  REDIS_SESSION_MAXMEMORY_MB
  REDIS_QUEUE_MAXMEMORY_MB
  REDIS_WS_MAXMEMORY_MB
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=shared/common.sh
source "$script_dir/shared/common.sh"

redis_dir="$repo_dir/redis"
template_dir="${REDIS_TEMPLATE_DIR:-$redis_dir/templates}"
output_dir="${REDIS_CONFIG_DIR:-$redis_dir/redis_config}"
env_file="$redis_dir/.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path"
      env_file="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a path"
      output_dir="$2"
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

"$script_dir/redis-env-check.sh" ensure-env --env-file "$env_file"

require_password() {
  local name="$1"
  local value="${!name:-}"

  [[ -n "$value" ]] || die "$name is required in $env_file"
  [[ ! "$value" =~ [[:space:]#] ]] || die "$name cannot contain whitespace or #"
  printf '%s\n' "$value"
}

render_template() {
  local role="$1"
  local password="$2"
  local maxmemory_mb="$3"
  local policy="$4"
  local samples="$5"
  local persistence_block="$6"
  local lazyfree_block="$7"
  local output="$8"
  local template="$template_dir/redis.conf.tpl"
  local tmp content

  [[ -f "$template" ]] || die "missing template: $template"
  content="$(< "$template")"

  replace() {
    local key="$1"
    local value="$2"
    content="${content//\{\{$key\}\}/$value}"
  }

  replace GENERATED_AT "$generated_at"
  replace ROLE "$role"
  replace HOST_MEMORY_MB "$memory_mb"
  replace CPU_CORES "$cpu_cores"
  replace HOST_MEMORY_RESERVE_PERCENT "$host_memory_reserve_percent"
  replace HOST_MEMORY_RESERVED_MB "$host_memory_reserved_mb"
  replace REDIS_MEMORY_BUDGET_PERCENT "$redis_memory_budget_percent"
  replace REDIS_MEMORY_BUDGET_MB "$redis_memory_budget_mb"
  replace PASSWORD "$password"
  replace MAXMEMORY_MB "$maxmemory_mb"
  replace MAXMEMORY_POLICY "$policy"
  replace MAXMEMORY_SAMPLES "$samples"
  replace PERSISTENCE_BLOCK "$persistence_block"
  replace LAZYFREE_BLOCK "$lazyfree_block"

  tmp="$(mktemp "${output}.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$output"
  chmod 0644 "$output"
}

mem_limit_mb() {
  local maxmemory_mb="$1"
  local overhead_percent="$2"
  local minimum_overhead_mb="$3"
  local limit_mb overhead_mb

  overhead_mb="$(( maxmemory_mb * overhead_percent / 100 ))"
  overhead_mb="$(clamp_min "$overhead_mb" "$minimum_overhead_mb")"
  limit_mb="$(( maxmemory_mb + overhead_mb ))"
  round_to_step "$limit_mb" 16
}

load_env_file "$env_file" --preserve-existing

cache_password="$(require_password REDIS_CACHE_PASSWORD)"
session_password="$(require_password REDIS_SESSION_PASSWORD)"
queue_password="$(require_password REDIS_QUEUE_PASSWORD)"
ws_password="$(require_password REDIS_WS_PASSWORD)"

memory_mb="$(detect_memory_mb REDIS_MEMORY_MB)"
cpu_cores="$(detect_cpu_cores REDIS_CPU_CORES)"
require_positive_uint detected_memory_mb "$memory_mb"
require_positive_uint detected_cpu_cores "$cpu_cores"

host_memory_reserve_percent="$(setting_positive_uint REDIS_HOST_MEMORY_RESERVE_PERCENT 10)"
(( host_memory_reserve_percent < 100 )) || die "REDIS_HOST_MEMORY_RESERVE_PERCENT must be less than 100"
host_memory_reserved_mb="$(( memory_mb * host_memory_reserve_percent / 100 ))"
redis_tuning_memory_mb="$(( memory_mb - host_memory_reserved_mb ))"
(( redis_tuning_memory_mb > 0 )) || die "Redis tuning memory must be greater than zero"

redis_memory_budget_percent="$(setting_positive_uint REDIS_MEMORY_BUDGET_PERCENT 70)"
(( redis_memory_budget_percent <= 100 )) || die "REDIS_MEMORY_BUDGET_PERCENT must be 100 or less"
redis_memory_budget_mb="$(( redis_tuning_memory_mb * redis_memory_budget_percent / 100 ))"
redis_memory_budget_mb="$(clamp_min "$redis_memory_budget_mb" 256)"

cache_default_mb="$(round_to_step "$(( redis_memory_budget_mb * 30 / 100 ))" 16)"
ws_default_mb="$(round_to_step "$(( redis_memory_budget_mb * 5 / 100 ))" 16)"
session_default_mb="$(round_to_step "$(( redis_memory_budget_mb * 13 / 100 ))" 16)"
queue_default_mb="$(( redis_memory_budget_mb - cache_default_mb - ws_default_mb - session_default_mb ))"
queue_default_mb="$(round_to_step "$queue_default_mb" 16)"

cache_maxmemory_mb="$(setting_positive_uint REDIS_CACHE_MAXMEMORY_MB "$(clamp_min "$cache_default_mb" 64)")"
ws_maxmemory_mb="$(setting_positive_uint REDIS_WS_MAXMEMORY_MB "$(clamp_min "$ws_default_mb" 32)")"
session_maxmemory_mb="$(setting_positive_uint REDIS_SESSION_MAXMEMORY_MB "$(clamp_min "$session_default_mb" 64)")"
queue_maxmemory_mb="$(setting_positive_uint REDIS_QUEUE_MAXMEMORY_MB "$(clamp_min "$queue_default_mb" 128)")"

container_overhead_percent="$(setting_positive_uint REDIS_CONTAINER_MEMORY_OVERHEAD_PERCENT 30)"
queue_container_overhead_percent="$(setting_positive_uint REDIS_QUEUE_CONTAINER_MEMORY_OVERHEAD_PERCENT 50)"

cache_mem_limit_mb="$(setting_positive_uint REDIS_CACHE_MEM_LIMIT_MB "$(mem_limit_mb "$cache_maxmemory_mb" "$container_overhead_percent" 64)")"
ws_mem_limit_mb="$(setting_positive_uint REDIS_WS_MEM_LIMIT_MB "$(mem_limit_mb "$ws_maxmemory_mb" "$container_overhead_percent" 64)")"
session_mem_limit_mb="$(setting_positive_uint REDIS_SESSION_MEM_LIMIT_MB "$(mem_limit_mb "$session_maxmemory_mb" "$container_overhead_percent" 64)")"
queue_mem_limit_mb="$(setting_positive_uint REDIS_QUEUE_MEM_LIMIT_MB "$(mem_limit_mb "$queue_maxmemory_mb" "$queue_container_overhead_percent" 128)")"

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
mkdir -p "$output_dir"

ephemeral_persistence=$'appendonly no\nsave ""'
evictable_lazyfree=$'lazyfree-lazy-eviction yes\nlazyfree-lazy-expire yes'
queue_persistence=$'appendonly yes\nappendfsync everysec\nauto-aof-rewrite-percentage 100\nauto-aof-rewrite-min-size 32mb\naof-use-rdb-preamble yes\naof-load-truncated yes\nno-appendfsync-on-rewrite yes\nsave 60 1\nsave 300 10\nstop-writes-on-bgsave-error yes\nrdbcompression yes\nrdbchecksum yes\ndbfilename dump.rdb'
queue_lazyfree='lazyfree-lazy-user-del yes'

render_template "cache" "$cache_password" "$cache_maxmemory_mb" "allkeys-lru" "7" "$ephemeral_persistence" "$evictable_lazyfree" "$output_dir/cache.conf"
render_template "websocket" "$ws_password" "$ws_maxmemory_mb" "allkeys-lru" "5" "$ephemeral_persistence" "$evictable_lazyfree" "$output_dir/ws.conf"
render_template "session" "$session_password" "$session_maxmemory_mb" "volatile-ttl" "7" "$ephemeral_persistence" "$evictable_lazyfree" "$output_dir/session.conf"
render_template "queue" "$queue_password" "$queue_maxmemory_mb" "noeviction" "5" "$queue_persistence" "$queue_lazyfree" "$output_dir/queue.conf"

compose_env="$output_dir/compose.env"
compose_tmp="$(mktemp "${compose_env}.tmp.XXXXXX")"
{
  printf '# Generated by scripts/generate-redis-config.sh on %s\n' "$generated_at"
  printf 'REDIS_CACHE_MEM_LIMIT=%sm\n' "$cache_mem_limit_mb"
  printf 'REDIS_WS_MEM_LIMIT=%sm\n' "$ws_mem_limit_mb"
  printf 'REDIS_SESSION_MEM_LIMIT=%sm\n' "$session_mem_limit_mb"
  printf 'REDIS_QUEUE_MEM_LIMIT=%sm\n' "$queue_mem_limit_mb"
} > "$compose_tmp"
mv "$compose_tmp" "$compose_env"
chmod 0644 "$compose_env"

printf 'Generated Redis configs in %s\n' "$output_dir"
printf 'Detected resources: %sMB RAM, %s CPU cores\n' "$memory_mb" "$cpu_cores"
printf 'Reserved for host/Docker: %s%% (%sMB); Redis budget: %s%% of %sMB = %sMB\n' \
  "$host_memory_reserve_percent" "$host_memory_reserved_mb" "$redis_memory_budget_percent" "$redis_tuning_memory_mb" "$redis_memory_budget_mb"
printf 'Maxmemory: cache=%smb ws=%smb session=%smb queue=%smb\n' \
  "$cache_maxmemory_mb" "$ws_maxmemory_mb" "$session_maxmemory_mb" "$queue_maxmemory_mb"
printf 'Container limits: cache=%sm ws=%sm session=%sm queue=%sm\n' \
  "$cache_mem_limit_mb" "$ws_mem_limit_mb" "$session_mem_limit_mb" "$queue_mem_limit_mb"
