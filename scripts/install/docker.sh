#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd -- "$SCRIPT_DIR/../shared" && pwd)"

# shellcheck source=../shared/common.sh
source "$SHARED_DIR/common.sh"
# shellcheck source=../shared/colors-and-messages.sh
source "$SHARED_DIR/colors-and-messages.sh"

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
}

detect_docker_repo() {
  local os_id os_id_like suite

  [[ -r /etc/os-release ]] || die "missing /etc/os-release; cannot detect Linux distribution"
  # shellcheck source=/dev/null
  . /etc/os-release

  os_id="${ID:-}"
  os_id_like=" ${ID_LIKE:-} "
  suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

  case "$os_id" in
    ubuntu)
      repo_os="ubuntu"
      ;;
    debian)
      repo_os="debian"
      ;;
    *)
      if [[ "$os_id_like" == *" ubuntu "* && -n "${UBUNTU_CODENAME:-}" ]]; then
        repo_os="ubuntu"
        suite="$UBUNTU_CODENAME"
      else
        die "this installer supports Ubuntu and Debian hosts only; detected ID=${os_id:-unknown}"
      fi
      ;;
  esac

  [[ -n "$suite" ]] || die "could not detect distro codename from /etc/os-release"
  repo_suite="$suite"
}

sudo_cmd() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

remove_conflicting_packages() {
  local package status
  local installed_packages=()
  local conflicting_packages=(
    docker.io
    docker-doc
    docker-compose
    docker-compose-v2
    podman-docker
    containerd
    runc
  )

  for package in "${conflicting_packages[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    [[ "$status" == i* ]] && installed_packages+=("$package")
  done

  if (( ${#installed_packages[@]} == 0 )); then
    pinfo "No conflicting Docker packages found."
    return 0
  fi

  pinfo "Removing conflicting Docker packages: ${installed_packages[*]}"
  sudo_cmd apt-get remove -y "${installed_packages[@]}"
}

target_docker_user() {
  if [[ -n "${DOCKER_USER:-}" ]]; then
    printf '%s\n' "$DOCKER_USER"
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

configure_docker_group() {
  local user_name="$1"

  if [[ "$user_name" == "root" ]]; then
    pwarn "Skipping docker group membership for root."
    return 0
  fi

  if ! id "$user_name" >/dev/null 2>&1; then
    die "target Docker user does not exist: $user_name"
  fi

  pinfo "Adding $user_name to the docker group."
  sudo_cmd groupadd -f docker
  sudo_cmd usermod -aG docker "$user_name"
  pwarn "The docker group grants root-level access. Log out and back in before running docker without sudo."
}

enable_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    pwarn "systemctl is not available; skipping Docker service enable/restart."
    return 0
  fi

  pinfo "Enabling and restarting Docker services."
  sudo_cmd systemctl enable docker.service
  sudo_cmd systemctl enable containerd.service
  sudo_cmd systemctl restart docker.service
}

require_command apt-get
require_command dpkg
require_command dpkg-query

if (( EUID != 0 )); then
  require_command sudo
  sudo -v
fi

export DEBIAN_FRONTEND=noninteractive

detect_docker_repo
architecture="$(dpkg --print-architecture)"
docker_user="$(target_docker_user)"

pinfo "Installing Docker Engine for $repo_os $repo_suite ($architecture)."
remove_conflicting_packages

pinfo "Adding Docker's official apt repository."
sudo_cmd apt-get update -y
sudo_cmd apt-get install -y ca-certificates curl
sudo_cmd install -m 0755 -d /etc/apt/keyrings
sudo_cmd curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o /etc/apt/keyrings/docker.asc
sudo_cmd chmod a+r /etc/apt/keyrings/docker.asc

sudo_cmd tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${repo_os}
Suites: ${repo_suite}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo_cmd apt-get update -y

pinfo "Installing Docker packages."
sudo_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

configure_docker_group "$docker_user"
enable_services

psuccess "Docker is installed."
docker --version || true
docker compose version || true
