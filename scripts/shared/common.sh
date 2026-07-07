#!/usr/bin/env bash

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  local answer

  if (( ${assume_yes:-0} == 1 )); then
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

  die "could not generate a random password; install openssl or provide passwords manually"
}

trim_env_value() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s\n' "$value"
}

env_file_value() {
  local name="$1"
  local file="${2:-${env_file:-}}"
  local line key value found=""

  [[ -n "$file" ]] || die "env_file_value requires an env file path"
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      [[ "$key" == "$name" ]] || continue
      found="$(trim_env_value "$value")"
    fi
  done < "$file"

  printf '%s\n' "$found"
}

set_env_file_value() {
  local name="$1"
  local value="$2"
  local file="${3:-${env_file:-}}"
  local tmp

  [[ -n "$file" ]] || die "set_env_file_value requires an env file path"
  [[ -f "$file" ]] || die "missing env file: $file"

  tmp="$(mktemp "${file}.tmp.XXXXXX")"
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
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
  chmod 0600 "$file"
}

load_env_file() {
  local file="$1"
  local mode="${2:-}"
  local line key value

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(trim_env_value "${BASH_REMATCH[2]}")"

      if [[ "$mode" == "--preserve-existing" && -n "${!key+x}" ]]; then
        continue
      fi

      export "$key=$value"
    fi
  done < "$file"
}

load_required_env_file() {
  local file="$1"
  local message="${2:-missing env file: $file}"

  [[ -f "$file" ]] || die "$message"
  load_env_file "$file"
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

setting_uint() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"

  require_uint "$name" "$value"
  printf '%s\n' "$value"
}

setting_positive_uint() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"

  require_positive_uint "$name" "$value"
  printf '%s\n' "$value"
}

setting_raw() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"

  require_non_empty "$name" "$value"
  printf '%s\n' "$value"
}

detect_memory_mb() {
  local override_name="$1"
  local override_value="${!override_name:-}"
  local pages page_size

  if [[ -n "$override_value" ]]; then
    require_positive_uint "$override_name" "$override_value"
    printf '%s\n' "$override_value"
    return 0
  fi

  if [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo
    return 0
  fi

  if pages="$(getconf _PHYS_PAGES 2>/dev/null)" && page_size="$(getconf PAGE_SIZE 2>/dev/null)"; then
    printf '%s\n' "$(( pages * page_size / 1024 / 1024 ))"
    return 0
  fi

  die "could not detect host memory; set $override_name"
}

detect_cpu_cores() {
  local override_name="$1"
  local override_value="${!override_name:-}"
  local cores

  if [[ -n "$override_value" ]]; then
    require_positive_uint "$override_name" "$override_value"
    printf '%s\n' "$override_value"
    return 0
  fi

  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi

  if cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"; then
    printf '%s\n' "$cores"
    return 0
  fi

  printf '1\n'
}

clamp() {
  local value="$1"
  local min="$2"
  local max="$3"

  (( value < min )) && value="$min"
  (( value > max )) && value="$max"
  printf '%s\n' "$value"
}

clamp_min() {
  local value="$1"
  local min="$2"

  (( value < min )) && value="$min"
  printf '%s\n' "$value"
}

round_to_step() {
  local value="$1"
  local step="$2"

  printf '%s\n' "$(( ((value + (step / 2)) / step) * step ))"
}

format_mb() {
  local value="$1"

  if (( value >= 1024 && value % 1024 == 0 )); then
    printf '%sGB\n' "$(( value / 1024 ))"
  else
    printf '%sMB\n' "$value"
  fi
}

resolve_path_relative_to() {
  local base_dir="$1"
  local path="$2"

  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$base_dir" "$path"
  fi
}
