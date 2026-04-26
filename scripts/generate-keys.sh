#!/usr/bin/env bash
# generate-keys.sh — Generate SSH key pairs used by the homelab.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

generate_key() {
  local path="$1" comment="$2"
  if [[ -f "$path" ]]; then
    warn "Already exists, skipping: $path"
  else
    ssh-keygen -t ed25519 -f "$path" -C "$comment" -N ""
    info "Generated $path"
  fi
}

generate_key ~/.ssh/homelab     "homelab-lxc"
generate_key ~/.ssh/k3s_cluster "k3s-cluster"

info "Done. Add to ssh-agent with: ssh-add ~/.ssh/homelab ~/.ssh/k3s_cluster"
