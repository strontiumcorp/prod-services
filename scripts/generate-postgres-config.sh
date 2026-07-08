#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate Postgres config files from templates and host resources.

Usage:
  scripts/generate-postgres-config.sh [--env-file PATH] [--output-dir PATH]

Defaults:
  --env-file   postgres/.env when it exists
  --output-dir postgres/pg_config

Useful .env overrides:
  POSTGRES_MEMORY_MB
  POSTGRES_CPU_CORES
  POSTGRES_HOST_MEMORY_RESERVE_PERCENT
  POSTGRES_ALLOWED_CIDRS
  POSTGRES_MAX_CONNECTIONS
  POSTGRES_SHARED_BUFFERS
  POSTGRES_EFFECTIVE_CACHE_SIZE
  POSTGRES_WORK_MEM
  POSTGRES_MAINTENANCE_WORK_MEM
  POSTGRES_AUTOVACUUM_MAX_WORKERS
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=shared/common.sh
source "$script_dir/shared/common.sh"

postgres_dir="$repo_dir/postgres"
template_dir="${POSTGRES_TEMPLATE_DIR:-$postgres_dir/templates}"
output_dir="${POSTGRES_CONFIG_DIR:-$postgres_dir/pg_config}"
env_file="$postgres_dir/.env"

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

"$script_dir/postgres-env-check.sh" ensure-env --env-file "$env_file"

build_allowed_cidr_lines() {
  local configured="${POSTGRES_ALLOWED_CIDRS:-10.1.0.0/24}"
  local normalized cidr line output=""

  normalized="${configured//,/ }"
  for cidr in $normalized; do
    [[ "$cidr" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || die "invalid CIDR in POSTGRES_ALLOWED_CIDRS: $cidr"
    line="$(printf 'host    all   all   %-18s scram-sha-256' "$cidr")"
    output="${output}${line}"$'\n'
  done

  if [[ -z "$output" ]]; then
    output="# No remote CIDRs configured. Set POSTGRES_ALLOWED_CIDRS to allow app hosts."
  fi

  printf '%s' "$output"
}

render_template() {
  local template="$1"
  local output="$2"
  local tmp content

  [[ -f "$template" ]] || die "missing template: $template"
  content="$(< "$template")"

  replace() {
    local key="$1"
    local value="$2"
    content="${content//\{\{$key\}\}/$value}"
  }

  replace GENERATED_AT "$generated_at"
  replace HOST_MEMORY_MB "$memory_mb"
  replace HOST_MEMORY_RESERVE_PERCENT "$host_memory_reserve_percent"
  replace HOST_MEMORY_RESERVED_MB "$host_memory_reserved_mb"
  replace POSTGRES_TUNING_MEMORY_MB "$postgres_tuning_memory_mb"
  replace CPU_CORES "$cpu_cores"
  replace MAX_CONNECTIONS "$max_connections"
  replace SHARED_BUFFERS "$shared_buffers"
  replace EFFECTIVE_CACHE_SIZE "$effective_cache_size"
  replace WORK_MEM "$work_mem"
  replace MAINTENANCE_WORK_MEM "$maintenance_work_mem"
  replace MAX_WAL_SIZE "$max_wal_size"
  replace MIN_WAL_SIZE "$min_wal_size"
  replace MAX_WORKER_PROCESSES "$max_worker_processes"
  replace MAX_PARALLEL_WORKERS "$max_parallel_workers"
  replace MAX_PARALLEL_WORKERS_PER_GATHER "$max_parallel_workers_per_gather"
  replace AUTOVACUUM_MAX_WORKERS "$autovacuum_max_workers"
  replace LOG_MIN_DURATION_STATEMENT "$log_min_duration_statement"
  replace ALLOWED_CIDR_LINES "$allowed_cidr_lines"

  tmp="$(mktemp "${output}.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$output"
  chmod 0644 "$output"
}

load_env_file "$env_file" --preserve-existing

memory_mb="$(detect_memory_mb POSTGRES_MEMORY_MB)"
cpu_cores="$(detect_cpu_cores POSTGRES_CPU_CORES)"
require_positive_uint detected_memory_mb "$memory_mb"
require_positive_uint detected_cpu_cores "$cpu_cores"

host_memory_reserve_percent="$(setting_uint POSTGRES_HOST_MEMORY_RESERVE_PERCENT 10)"
(( host_memory_reserve_percent < 100 )) || die "POSTGRES_HOST_MEMORY_RESERVE_PERCENT must be less than 100"
host_memory_reserved_mb="$(( memory_mb * host_memory_reserve_percent / 100 ))"
postgres_tuning_memory_mb="$(( memory_mb - host_memory_reserved_mb ))"
(( postgres_tuning_memory_mb > 0 )) || die "Postgres tuning memory must be greater than zero"

max_connections_default="$(( cpu_cores * 25 ))"
max_connections_default="$(clamp "$max_connections_default" 50 200)"
memory_connection_cap="$(( postgres_tuning_memory_mb / 64 ))"
memory_connection_cap="$(clamp "$memory_connection_cap" 50 200)"
(( max_connections_default > memory_connection_cap )) && max_connections_default="$memory_connection_cap"
max_connections="$(setting_uint POSTGRES_MAX_CONNECTIONS "$max_connections_default")"

shared_buffers_mb="$(( postgres_tuning_memory_mb / 4 ))"
shared_buffers_mb="$(round_to_step "$shared_buffers_mb" 128)"
shared_buffers_mb="$(clamp "$shared_buffers_mb" 128 8192)"

effective_cache_size_mb="$(( postgres_tuning_memory_mb * 3 / 4 ))"
effective_cache_size_mb="$(round_to_step "$effective_cache_size_mb" 128)"
effective_cache_size_mb="$(clamp "$effective_cache_size_mb" 256 "$(( postgres_tuning_memory_mb - 128 ))")"

maintenance_work_mem_mb="$(( postgres_tuning_memory_mb / 16 ))"
maintenance_work_mem_mb="$(round_to_step "$maintenance_work_mem_mb" 64)"
maintenance_work_mem_mb="$(clamp "$maintenance_work_mem_mb" 64 2048)"

available_for_work_mb="$(( postgres_tuning_memory_mb - shared_buffers_mb - maintenance_work_mem_mb ))"
(( available_for_work_mb > 0 )) || available_for_work_mb="$(( postgres_tuning_memory_mb / 2 ))"
work_mem_mb="$(( available_for_work_mb / max_connections / 2 ))"
work_mem_mb="$(clamp "$work_mem_mb" 4 64)"

if (( postgres_tuning_memory_mb < 4096 )); then
  max_wal_size_default="1GB"
  min_wal_size_default="256MB"
elif (( postgres_tuning_memory_mb < 8192 )); then
  max_wal_size_default="2GB"
  min_wal_size_default="512MB"
else
  max_wal_size_default="4GB"
  min_wal_size_default="1GB"
fi

shared_buffers="$(setting_raw POSTGRES_SHARED_BUFFERS "$(format_mb "$shared_buffers_mb")")"
effective_cache_size="$(setting_raw POSTGRES_EFFECTIVE_CACHE_SIZE "$(format_mb "$effective_cache_size_mb")")"
work_mem="$(setting_raw POSTGRES_WORK_MEM "$(format_mb "$work_mem_mb")")"
maintenance_work_mem="$(setting_raw POSTGRES_MAINTENANCE_WORK_MEM "$(format_mb "$maintenance_work_mem_mb")")"
max_wal_size="$(setting_raw POSTGRES_MAX_WAL_SIZE "$max_wal_size_default")"
min_wal_size="$(setting_raw POSTGRES_MIN_WAL_SIZE "$min_wal_size_default")"
max_worker_processes="$(setting_uint POSTGRES_MAX_WORKER_PROCESSES "$(clamp "$cpu_cores" 8 32)")"
max_parallel_workers="$(setting_uint POSTGRES_MAX_PARALLEL_WORKERS "$(clamp "$cpu_cores" 2 16)")"
max_parallel_workers_per_gather="$(setting_uint POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER "$(clamp "$(( cpu_cores / 2 ))" 1 4)")"
autovacuum_max_workers="$(setting_uint POSTGRES_AUTOVACUUM_MAX_WORKERS "$(clamp "$(( cpu_cores / 2 ))" 3 8)")"
log_min_duration_statement="$(setting_uint POSTGRES_LOG_MIN_DURATION_STATEMENT 500)"
allowed_cidr_lines="$(build_allowed_cidr_lines)"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$output_dir"
render_template "$template_dir/postgresql.conf.tpl" "$output_dir/postgresql.conf"
render_template "$template_dir/pg_hba.conf.tpl" "$output_dir/pg_hba.conf"

printf 'Generated %s/postgresql.conf and %s/pg_hba.conf\n' "$output_dir" "$output_dir"
printf 'Detected resources: %sMB RAM, %s CPU cores\n' "$memory_mb" "$cpu_cores"
printf 'Reserved for host/Docker: %s%% (%sMB); tuning Postgres from %sMB\n' \
  "$host_memory_reserve_percent" "$host_memory_reserved_mb" "$postgres_tuning_memory_mb"
printf 'Tuning: max_connections=%s shared_buffers=%s effective_cache_size=%s work_mem=%s maintenance_work_mem=%s\n' \
  "$max_connections" "$shared_buffers" "$effective_cache_size" "$work_mem" "$maintenance_work_mem"
