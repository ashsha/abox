#!/bin/bash
set -euo pipefail

LOG=/tmp/setup.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

OS=$(uname -s)
ARCH=$(uname -m)

case "$ARCH" in
  x86_64|amd64) ARCH_NORM=amd64 ;;
  aarch64|arm64) ARCH_NORM=arm64 ;;
  *) log "Unsupported architecture: $ARCH"; exit 1 ;;
esac

case "$OS" in
  Darwin) OS_NORM=darwin ;;
  Linux)  OS_NORM=linux ;;
  *) log "Unsupported OS: $OS"; exit 1 ;;
esac

log "=== abox setup start (OS=$OS_NORM, ARCH=$ARCH_NORM) ==="

if ! command -v tofu >/dev/null 2>&1; then
  log "Installing OpenTofu..."
  curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone
  log "OpenTofu installed"
else
  log "OpenTofu already present: $(tofu version | head -1)"
fi

if ! command -v k9s >/dev/null 2>&1; then
  log "Installing K9s..."
  curl -sS https://webi.sh/k9s | sh
  log "K9s installed"
else
  log "K9s already present"
fi

USER_SHELL=$(basename "${SHELL:-}")
case "$USER_SHELL" in
  zsh)
    RC_FILE="$HOME/.zshrc"
    ;;
  bash)
    if [ -f "$HOME/.bash_profile" ]; then
      RC_FILE="$HOME/.bash_profile"
    elif [ -f "$HOME/.bashrc" ]; then
      RC_FILE="$HOME/.bashrc"
    elif [ "$OS_NORM" = "darwin" ]; then
      RC_FILE="$HOME/.bash_profile"
    else
      RC_FILE="$HOME/.bashrc"
    fi
    ;;
  fish)
    log "Detected fish shell — skipping alias install (fish syntax differs)."
    log "  Add manually to ~/.config/fish/config.fish:"
    log "    alias kk \"EDITOR='code --wait' k9s\""
    log "    alias tf tofu"
    log "    alias k kubectl"
    RC_FILE=""
    ;;
  *)
    if [ "$OS_NORM" = "darwin" ]; then
      RC_FILE="$HOME/.zshrc"
    else
      RC_FILE="$HOME/.bashrc"
    fi
    log "Unknown shell '$USER_SHELL' — falling back to $RC_FILE"
    ;;
esac

ALIASES_BLOCK='
# abox aliases
alias kk="EDITOR='\''code --wait'\'' k9s"
alias tf=tofu
alias k=kubectl
'

install_aliases() {
  local rc="$1"
  [ -z "$rc" ] && return 0

  if [ "${ABOX_SKIP_ALIASES:-}" = "1" ]; then
    log "ABOX_SKIP_ALIASES=1 — skipping shell alias install."
    log "  To add manually later, append to $rc:"
    printf '%s\n' "$ALIASES_BLOCK"
    return 0
  fi

  if grep -q "abox aliases" "$rc" 2>/dev/null; then
    log "abox aliases already present in $rc"
    return 0
  fi

  local conflicts=()
  local name existing
  for name in kk tf k; do
    if grep -qE "^[[:space:]]*alias[[:space:]]+${name}=" "$rc" 2>/dev/null; then
      existing=$(grep -E "^[[:space:]]*alias[[:space:]]+${name}=" "$rc" | head -1 | sed 's/^[[:space:]]*//')
      conflicts+=("$existing")
    fi
  done

  if [ ! -t 0 ]; then
    log "Non-interactive shell — skipping alias install."
    log "  Re-run interactively, or append to $rc:"
    printf '%s\n' "$ALIASES_BLOCK"
    return 0
  fi

  echo
  echo "abox would add the following aliases to $rc:"
  printf '%s\n' "$ALIASES_BLOCK"

  local reply
  if [ ${#conflicts[@]} -gt 0 ]; then
    echo "WARNING: these existing aliases will be shadowed (last definition wins):"
    for existing in "${conflicts[@]}"; do
      echo "  - $existing"
    done
    echo
    read -r -p "Append abox aliases anyway? [y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) : ;;
      *) log "Skipped alias install"; return 0 ;;
    esac
  else
    read -r -p "Append abox aliases to $rc? [Y/n] " reply
    case "$reply" in
      [nN]|[nN][oO]) log "Skipped alias install"; return 0 ;;
      *) : ;;
    esac
  fi

  printf '%s\n' "$ALIASES_BLOCK" >> "$rc"
  log "Aliases added to $rc (open a new terminal or 'source $rc' to activate)"
}

install_aliases "$RC_FILE"

log "Running tofu init..."
cd bootstrap
tofu init
log "tofu init done"

log "Running tofu apply..."
tofu apply -auto-approve
log "tofu apply done"

export KUBECONFIG=~/.kube/config

cd ..

if ! command -v cloud-provider-kind >/dev/null 2>&1; then
  log "Installing cloud-provider-kind for ${OS_NORM}_${ARCH_NORM}..."
  TARBALL="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/v0.6.0/cloud-provider-kind_0.6.0_${OS_NORM}_${ARCH_NORM}.tar.gz"
  curl -fsSL "$TARBALL" -o /tmp/cloud-provider-kind.tar.gz
  tar -xzf /tmp/cloud-provider-kind.tar.gz -C /tmp cloud-provider-kind
  rm /tmp/cloud-provider-kind.tar.gz
  CPK_BIN=/tmp/cloud-provider-kind
  log "cloud-provider-kind extracted to $CPK_BIN"
else
  CPK_BIN=$(command -v cloud-provider-kind)
  log "cloud-provider-kind already present: $CPK_BIN"
fi

nohup "$CPK_BIN" > /tmp/cloud-provider-kind.log 2>&1 &
log "cloud-provider-kind started (pid $!)"

if [ "$OS_NORM" = "darwin" ]; then
  log "  Note: on macOS, if LoadBalancer Services stay <pending> or unreachable,"
  log "  re-launch with sudo: sudo $CPK_BIN"
  log "  (Docker Desktop user-space networking sometimes needs root for host routes;"
  log "   Podman/Colima with gvproxy typically does not.)"
fi

log "=== setup complete ==="
