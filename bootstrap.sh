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

is_repo_ready() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  [ -f "$dir/playbooks/site.yml" ] || return 1
  [ -d "$dir/roles" ] || return 1
  [ -f "$dir/vault/vault_pass.txt.vault" ] || return 1
  return 0
}

ensure_repo() {
  local candidate="$1"
  if is_repo_ready "$candidate"; then
    printf '%s\n' "$candidate"
    return
  fi

  if [ -n "${BOOTSTRAP_REPO_PATH:-}" ]; then
    if is_repo_ready "$BOOTSTRAP_REPO_PATH"; then
      printf '%s\n' "$BOOTSTRAP_REPO_PATH"
      return
    fi
    err "Provided BOOTSTRAP_REPO_PATH ($BOOTSTRAP_REPO_PATH) is missing required files."
    exit 1
  fi

  local repo_url="${BOOTSTRAP_REPO_URL:-https://path-to-repo.git}"
  if ! command -v git >/dev/null 2>&1; then
    err "Repository assets not found locally and git is unavailable. Install git or set BOOTSTRAP_REPO_PATH."
    exit 1
  fi

  local temp_dir
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/gip_ans_repo.XXXXXX")
  log "Cloning repository from $repo_url into $temp_dir"
  if ! git clone --depth=1 "$repo_url" "$temp_dir" >/tmp/bootstrap_git.log 2>&1; then
    err "Failed to clone repository from $repo_url. See /tmp/bootstrap_git.log for details."
    rm -rf "$temp_dir"
    exit 1
  fi
  BOOTSTRAP_CLEANUP_REPO="$temp_dir"
  printf '%s\n' "$temp_dir"
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
    local current_dir cmd tty_device
    current_dir=$(pwd)
    cmd=$(printf ' %q' "$@")
    cmd=${cmd# }
    tty_device=$(tty 2>/dev/null || true)

    if [ -n "$tty_device" ] && [ "$tty_device" != "not a tty" ]; then
      su root -c "cd $(printf '%q' "$current_dir") && $cmd" < "$tty_device"
    elif [ -r /dev/tty ]; then
      su root -c "cd $(printf '%q' "$current_dir") && $cmd" < /dev/tty
    else
      err "su fallback requires an interactive terminal. Please run bootstrap from a tty or configure sudo."
      exit 1
    fi
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
  printf '%s' "$bootstrap_pass" > "$tmp_pw"

  if ! ansible-vault view "$repo_vault_file" --vault-password-file "$tmp_pw" > "$local_vault_file" 2>/tmp/vault_view.log; then
    err "Unable to decrypt vault password file. See /tmp/vault_view.log for details."
    rm -f "$tmp_pw"
    rm -f "$local_vault_file"
    exit 1
  fi
  rm -f "$tmp_pw"
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
  repo_dir="$(ensure_repo "$repo_dir")"
  if [ -n "${BOOTSTRAP_CLEANUP_REPO:-}" ]; then
    trap 'rm -rf "$BOOTSTRAP_CLEANUP_REPO"' EXIT
  fi
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
