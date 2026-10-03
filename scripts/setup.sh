#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/setup.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# have reports whether a tool is already on PATH. Every installer below is
# guarded by it so that re-runs, and machines where the tools came from a
# package manager (Homebrew, apt, nix), do not pull a second copy, prompt
# for sudo, or let webi edit shell rc files.
have() { command -v "$1" >/dev/null 2>&1; }

log "=== abox setup start ==="

# Detect the platform once. kind and cloud-provider-kind both publish
# linux/darwin builds for amd64/arm64 under the same naming scheme.
case "$(uname -s)" in
  Linux)  PLATFORM_OS=linux ;;
  Darwin) PLATFORM_OS=darwin ;;
  *)      PLATFORM_OS= ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  PLATFORM_ARCH=amd64 ;;
  arm64|aarch64) PLATFORM_ARCH=arm64 ;;
  *)             PLATFORM_ARCH= ;;
esac
if [[ -z "${PLATFORM_OS}" || -z "${PLATFORM_ARCH}" ]]; then
  log "Unsupported platform $(uname -s)/$(uname -m); binary installs will be skipped"
fi

# Install OpenTofu
if have tofu; then
  log "OpenTofu already present: $(tofu version | head -1)"
else
  log "Installing OpenTofu..."
  curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone
  log "OpenTofu installed"
fi

# Install kind CLI. The cluster itself is created by the tehcyx/kind Terraform
# provider, which embeds kind, but the CLI is needed for node-level work:
# kind get nodes, kind load docker-image, kind export logs.
if have kind; then
  log "kind already present: $(kind version)"
elif [[ -n "${PLATFORM_OS}" && -n "${PLATFORM_ARCH}" ]]; then
  log "Installing kind..."
  KIND_VERSION=v0.33.0
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${PLATFORM_OS}-${PLATFORM_ARCH}"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
  log "kind installed ($(kind version))"
else
  log "Skipping kind install"
fi

# Install K9s
if have k9s; then
  log "K9s already present"
else
  log "Installing K9s..."
  curl -sS https://webi.sh/k9s | sh
  log "K9s installed"
fi

# Shell aliases. The rc file is chosen from $SHELL rather than assumed to be
# ~/.bashrc: macOS terminals start bash as a login shell, which reads
# ~/.bash_profile and never sources ~/.bashrc unless the user wired that up.
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
    elif [ "$PLATFORM_OS" = "darwin" ]; then
      RC_FILE="$HOME/.bash_profile"
    else
      RC_FILE="$HOME/.bashrc"
    fi
    ;;
  fish)
    log "Detected fish shell, skipping alias install (fish syntax differs)."
    log "  Add manually to ~/.config/fish/config.fish:"
    log "    alias kk \"EDITOR='code --wait' k9s\""
    log "    alias tf tofu"
    log "    alias k kubectl"
    RC_FILE=""
    ;;
  *)
    if [ "$PLATFORM_OS" = "darwin" ]; then
      RC_FILE="$HOME/.zshrc"
    else
      RC_FILE="$HOME/.bashrc"
    fi
    log "Unknown shell '$USER_SHELL', falling back to $RC_FILE"
    ;;
esac

ALIASES_BLOCK='
# abox aliases
alias kk="EDITOR='\''code --wait'\'' k9s"
alias tf=tofu
alias k=kubectl
'

# install_aliases appends ALIASES_BLOCK to the rc file once, and only with
# consent. The "abox aliases" sentinel makes re-runs idempotent. Existing
# k, tf or kk aliases declared inline in the same file are surfaced before
# the prompt, because a later alias silently wins and users who alias tf to
# terraform would otherwise lose it. Aliases defined in sourced files, via
# eval, or as functions are not detected; that is an accepted trade-off for
# a one-shot setup script. ABOX_SKIP_ALIASES=1 bypasses the whole step.
install_aliases() {
  local rc="$1"
  [ -z "$rc" ] && return 0

  if [ "${ABOX_SKIP_ALIASES:-}" = "1" ]; then
    log "ABOX_SKIP_ALIASES=1, skipping shell alias install."
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
    log "Non-interactive shell, skipping alias install."
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

# Repair nested-Docker egress before anything tries to pull an image. See
# scripts/fix-egress.sh for why Codespaces needs this.
log "Checking Docker egress..."
bash "${SCRIPT_DIR}/fix-egress.sh"

# Kubeconfig. By default kind merges the new context into $KUBECONFIG or
# ~/.kube/config and makes it current, which is convenient on a fresh
# machine but intrusive on one that already carries production contexts.
# ABOX_KUBECONFIG points both kind (through the Terraform variable) and this
# shell at a dedicated file instead, leaving the user's main kubeconfig
# untouched.
if [[ -n "${ABOX_KUBECONFIG:-}" ]]; then
  # A quoted "~/..." reaches us unexpanded; kubectl does not expand it either.
  ABOX_KUBECONFIG="${ABOX_KUBECONFIG/#\~/$HOME}"
  export KUBECONFIG="${ABOX_KUBECONFIG}"
  export TF_VAR_kubeconfig_path="${ABOX_KUBECONFIG}"
  log "Using dedicated kubeconfig ${KUBECONFIG}"
else
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
fi

# Initialize Tofu
log "Running tofu init..."
cd bootstrap
tofu init
log "tofu init done"

log "Running tofu apply..."
tofu apply -auto-approve
log "tofu apply done"

# The bootstrap Job and every Flux-managed image are pulled by kubelet on the
# kind nodes, so confirm the nodes can actually reach a registry.
bash "${SCRIPT_DIR}/fix-egress.sh" verify abox \
  || log "WARNING: nodes cannot reach a registry, Flux will not reconcile"

cd ..

# Install cloud-provider-kind (LoadBalancer support)
CPK_BIN=
if have cloud-provider-kind; then
  CPK_BIN=$(command -v cloud-provider-kind)
  log "cloud-provider-kind already present: ${CPK_BIN}"
elif [[ -n "${PLATFORM_OS}" && -n "${PLATFORM_ARCH}" ]]; then
  log "Installing cloud-provider-kind..."
  CPK_VERSION=0.11.1
  CPK_URL="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/v${CPK_VERSION}/cloud-provider-kind_${CPK_VERSION}_${PLATFORM_OS}_${PLATFORM_ARCH}.tar.gz"
  curl -fsSL "$CPK_URL" -o /tmp/cloud-provider-kind.tar.gz
  tar -xzf /tmp/cloud-provider-kind.tar.gz -C /tmp cloud-provider-kind
  rm -f /tmp/cloud-provider-kind.tar.gz
  CPK_BIN=/tmp/cloud-provider-kind
else
  log "Skipping cloud-provider-kind install"
fi

if [[ -n "${CPK_BIN}" ]]; then
  # On macOS cloud-provider-kind sees containers as remote and defaults to
  # port-mapping tunnels, which need root. OrbStack routes the kind subnet to
  # the host directly, so the tunnels are unnecessary and disabling them lets
  # the provider run unprivileged; the LoadBalancer IP is then reachable as
  # is. Docker Desktop has no such route and still needs sudo.
  CPK_ARGS=()
  if [[ "${PLATFORM_OS}" = "darwin" ]] \
     && docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi orbstack; then
    CPK_ARGS+=(--enable-lb-port-mapping=false)
    log "OrbStack detected, running cloud-provider-kind without port-mapping tunnels"
  fi
  nohup "${CPK_BIN}" "${CPK_ARGS[@]}" > /tmp/cloud-provider-kind.log 2>&1 &
  log "cloud-provider-kind started (pid $!)"
  if [[ "${PLATFORM_OS}" = "darwin" && ${#CPK_ARGS[@]} -eq 0 ]]; then
    log "  Note: on macOS, if LoadBalancer Services stay <pending> or unreachable,"
    log "  check /tmp/cloud-provider-kind.log and re-launch in its own terminal:"
    log "    sudo ${CPK_BIN}"
  fi
fi

if [[ -n "${ABOX_KUBECONFIG:-}" ]]; then
  log "Remember to export KUBECONFIG=${ABOX_KUBECONFIG} in shells that talk to this cluster"
fi

log "=== setup complete ==="
