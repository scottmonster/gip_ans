#!/usr/bin/env bash
# POSIX-friendly bootstrap for gip_ans
set -euo pipefail

log() {
  printf '[bootstrap] %s\n' "$*" >&2
}

err() {
  printf '[bootstrap][error] %s\n' "$*" >&2
}

script_dir() {
  local src="$0"
  while [ -h "$src" ]; do
    local dir
    dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)
    src="$(readlink "$src")"
    case "$src" in
      /*) ;; # already absolute
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

ensure_path() {
  case ":$PATH:" in
    *":$1:"*) ;; # already there
    *) PATH="$1:$PATH" ;;
  esac
}

run_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    if id -nG "${USER:-$(id -un)}" 2>/dev/null | tr ' ' '\n' | grep -qx "sudo"; then
      sudo "$@"
      return
    fi
  fi

  if command -v su >/dev/null 2>&1; then
    log "Elevating with su because current user lacks sudo group membership"
    local current_dir cmd
    current_dir=$(pwd)
    cmd=$(printf ' %q' "$@")
    cmd=${cmd# }
    su root -c "cd $(printf '%q' "$current_dir") && $cmd"
    return
  fi

  err "This step requires elevated privileges and neither usable sudo nor su was found."
  exit 1
}

install_ansible_linux() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing Ansible via apt"
    run_sudo apt-get update -y
    run_sudo apt-get install -y ansible
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing Ansible via dnf"
    run_sudo dnf install -y ansible
  elif command -v pacman >/dev/null 2>&1; then
    log "Installing Ansible via pacman"
    run_sudo pacman -Sy --noconfirm ansible
  elif command -v zypper >/dev/null 2>&1; then
    log "Installing Ansible via zypper"
    run_sudo zypper -n install ansible
  else
    err "Unsupported package manager. Install Ansible manually or ensure ansible-playbook is on PATH."
    exit 1
  fi
}

install_ansible_macos() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    log "Installing Ansible via Homebrew"
    brew install ansible
    return
  fi
  err "Homebrew not found. Install Homebrew or Ansible manually before rerunning bootstrap."
  exit 1
}

install_ansible_windows() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return
  fi
  if command -v pipx >/dev/null 2>&1; then
    log "Installing ansible-core via pipx"
    pipx install --include-deps ansible-core >/dev/null 2>&1 || pipx reinstall ansible-core >/dev/null 2>&1 || true
    ensure_path "$HOME/.local/bin"
    return
  fi
  err "pipx not found. Install pipx (https://pipx.pypa.io) or Ansible manually before rerunning bootstrap."
  exit 1
}

ensure_ansible() {
  case "$(uname -s)" in
    Linux*) install_ansible_linux ;;
    Darwin*) install_ansible_macos ;;
    CYGWIN*|MINGW*|MSYS*) install_ansible_windows ;;
    *) err "Unsupported OS: $(uname -s). Install Ansible manually and rerun."; exit 1 ;;
  esac

  if ! command -v ansible-playbook >/dev/null 2>&1; then
    err "ansible-playbook not found after installation attempt. Please install Ansible and rerun."
    exit 1
  fi
  ensure_path "$HOME/.local/bin"
}

resolve_vault_password() {
  local repo_vault_file="$1"
  local local_vault_file="$2"
  local config_dir
  config_dir="$(dirname "$local_vault_file")"
  mkdir -p "$config_dir"

  if [ -f "$local_vault_file" ]; then
    return
  fi

  if [ ! -f "$repo_vault_file" ]; then
    err "Encrypted vault password seed not found at $repo_vault_file"
    exit 1
  fi

  printf 'Vault password not found locally. Enter bootstrap decryption password: ' >&2
  stty -echo
  IFS= read -r bootstrap_pass
  stty echo
  printf '\n' >&2

  local tmp_pw
  tmp_pw=$(mktemp)
  trap 'rm -f "$tmp_pw"' EXIT
  printf '%s' "$bootstrap_pass" > "$tmp_pw"

  if ! ansible-vault view "$repo_vault_file" --vault-password-file "$tmp_pw" > "$local_vault_file" 2>/tmp/vault_view.log; then
    err "Unable to decrypt vault password file. See /tmp/vault_view.log for details."
    rm -f "$local_vault_file"
    exit 1
  fi
  rm -f "$tmp_pw"
  trap - EXIT
  chmod 600 "$local_vault_file"
  log "Vault password restored at $local_vault_file"
}

choose_profile() {
  local given="$1"
  if [ -n "$given" ]; then
    printf '%s' "$given"
    return
  fi

  local choice
  while :; do
    printf 'Select profile [personal/server] (default: personal): '
    IFS= read -r choice
    case "$choice" in
      ""|personal|server)
        [ -z "$choice" ] && choice="personal"
        printf '%s' "$choice"
        return
        ;;
      *)
        printf 'Invalid selection. Try again.\n' >&2
        ;;
    esac
  done
}

main() {
  local repo_dir
  repo_dir="$(script_dir)"
  cd "$repo_dir"

  ensure_ansible

  if [ -f "$repo_dir/collections/requirements.yml" ]; then
    log "Installing required Ansible collections"
    ansible-galaxy collection install -r "$repo_dir/collections/requirements.yml" >/tmp/ansible-galaxy.log || {
      err "Collection install failed. See /tmp/ansible-galaxy.log"
      exit 1
    }
  fi

  local local_vault_path config_root
  config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
  local_vault_path="$config_root/qyksys/vault_pass.txt"
  resolve_vault_password "$repo_dir/vault/vault_pass.txt.vault" "$local_vault_path"

  local default_profile="${PROFILE:-}" profile
  if [ $# -gt 0 ]; then
    default_profile="$1"
    shift
  fi
  profile="$(choose_profile "$default_profile")"

  log "Running Ansible profile: $profile"
  ansible-playbook \
    -i "$repo_dir/inventory/local.yml" \
    "$repo_dir/playbooks/site.yml" \
    --vault-password-file "$local_vault_path" \
    -e "profile=$profile" \
    "$@"
}

main "$@"
