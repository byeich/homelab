#!/usr/bin/env bash
# bootstrap.sh — Full cluster setup on MacOS.
#
# Run this after k3s nodes are provisioned and k3s.yml Ansible playbook has run.
# Usage:
#   chmod +x scripts/bootstrap.sh
#   ./scripts/bootstrap.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL_NODE_IP="${K3S_CONTROL_IP:-10.0.0.60}"
SSH_KEY="${K3S_SSH_KEY:-$HOME/.ssh/k3s_cluster}"
SSH_USER="debian"

ARGOCD_VERSION="7.x"
LONGHORN_VERSION="1.7.x"
TUNNEL_ID="a1c6f9ec-b941-4595-b755-3d43f45a2c1b"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
prompt()  { echo -e "${YELLOW}[INPUT]${NC} $*"; }
section() { echo -e "\n${GREEN}══════════════════════════════════════${NC}"; echo -e "${GREEN}  $*${NC}"; echo -e "${GREEN}══════════════════════════════════════${NC}"; }


section "Step 1: Mac prerequisites"
if ! command -v brew &>/dev/null; then
  echo -e "${RED}Homebrew not found. Install it first: https://brew.sh${NC}"
  exit 1
fi

for tool in helm kubectl kubeseal; do
  if ! command -v "$tool" &>/dev/null; then
    info "Installing $tool via brew..."
    brew install "$tool"
  else
    info "$tool already installed: $(command -v $tool)"
  fi
done

section "Step 2: Configure kubectl"
KUBECONFIG_PATH="$HOME/.kube/k3s-homelab.yaml"
mkdir -p "$HOME/.kube"

info "Copying kubeconfig from $CONTROL_NODE_IP..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$CONTROL_NODE_IP" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|https://127.0.0.1:6443|https://$CONTROL_NODE_IP:6443|g" \
  > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

export KUBECONFIG="$KUBECONFIG_PATH"
info "KUBECONFIG set to $KUBECONFIG_PATH"

info "Verifying cluster connectivity..."
kubectl get nodes

section "Step 3: Helm repos"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
helm repo update
info "Helm repos up to date."

section "Step 4: Install ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "$ARGOCD_VERSION" \
  --values "$REPO_ROOT/k8s/bootstrap/argocd/values.yaml" \
  --wait
info "ArgoCD installed."

section "Step 5: Install Longhorn via Helm"
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "$LONGHORN_VERSION" \
  --wait --timeout 10m
info "Longhorn installed."

section "Step 6: Install Sealed Secrets controller"
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller \
  --wait
info "Sealed Secrets controller installed."

section "Step 7: Seal secrets with kubeseal"
warn "You will now be prompted for secret values."
warn "These are not written to disk, but are piped directly through kubeseal."
warn "The output (encrypted SealedSecret) will be written to git-tracked files."

# Helper: seal a secret and write to file
seal_secret() {
  local name="$1" namespace="$2" output_file="$3"
  shift 3
  # remaining args are --from-literal or --from-file flags
  kubectl create secret generic "$name" -n "$namespace" "$@" \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --format yaml \
  > "$output_file"
  info "Sealed $name → $output_file"
}

# Vaultwarden
echo ""
prompt "Enter the Vaultwarden admin token (or press Enter to skip):"
read -r -s VAULTWARDEN_TOKEN
if [[ -n "$VAULTWARDEN_TOKEN" ]]; then
  kubectl create namespace vaultwarden --dry-run=client -o yaml | kubectl apply -f -
  seal_secret vaultwarden-secret vaultwarden \
    "$REPO_ROOT/k8s/apps/vaultwarden/sealed-secret.yaml" \
    --from-literal=admin-token="$VAULTWARDEN_TOKEN"
  unset VAULTWARDEN_TOKEN
else
  warn "Skipped vaultwarden-secret. Apply it manually before ArgoCD syncs vaultwarden."
fi

# Cloudflared
echo ""
TUNNEL_JSON="$REPO_ROOT/$TUNNEL_ID.json"
if [[ -f "$TUNNEL_JSON" ]]; then
  kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -
  seal_secret cloudflared-creds cloudflared \
    "$REPO_ROOT/k8s/apps/cloudflared/sealed-secret.yaml" \
    --from-file=credentials.json="$TUNNEL_JSON"
else
  prompt "Cloudflare tunnel credentials.json not found at $TUNNEL_JSON"
  prompt "Enter the full path to your credentials.json (or press Enter to skip):"
  read -r CREDS_PATH
  if [[ -n "$CREDS_PATH" && -f "$CREDS_PATH" ]]; then
    kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -
    seal_secret cloudflared-creds cloudflared \
      "$REPO_ROOT/k8s/apps/cloudflared/sealed-secret.yaml" \
      --from-file=credentials.json="$CREDS_PATH"
  else
    warn "Skipped cloudflared-creds. Apply it manually before ArgoCD syncs cloudflared."
  fi
fi

# Immich
echo ""
prompt "Enter the Immich DB password (or press Enter to skip):"
read -r -s IMMICH_DB_PASS
if [[ -n "$IMMICH_DB_PASS" ]]; then
  kubectl create namespace immich --dry-run=client -o yaml | kubectl apply -f -
  seal_secret immich-secret immich \
    "$REPO_ROOT/k8s/apps/immich/sealed-secret.yaml" \
    --from-literal=db-password="$IMMICH_DB_PASS"
  unset IMMICH_DB_PASS
else
  warn "Skipped immich-secret. Apply it manually before ArgoCD syncs immich."
fi

# Obsidian (CouchDB)
echo ""
prompt "Enter the Obsidian CouchDB admin password (or press Enter to skip):"
read -r -s OBSIDIAN_PASS
if [[ -n "$OBSIDIAN_PASS" ]]; then
  kubectl create namespace obsidian --dry-run=client -o yaml | kubectl apply -f -
  seal_secret obsidian-secret obsidian \
    "$REPO_ROOT/k8s/apps/obsidian/sealed-secret.yaml" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$OBSIDIAN_PASS"
  unset OBSIDIAN_PASS
else
  warn "Skipped obsidian-secret. Apply it manually before ArgoCD syncs obsidian."
fi

# Monitoring
echo ""
prompt "Enter the Telegram bot token for Alertmanager (or press Enter to skip):"
read -r -s TELEGRAM_TOKEN
if [[ -n "$TELEGRAM_TOKEN" ]]; then
  prompt "Enter the Grafana admin password:"
  read -r -s GRAFANA_PASS
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  seal_secret monitoring-secret monitoring \
    "$REPO_ROOT/k8s/apps/monitoring/sealed-secret.yaml" \
    --from-literal=telegram-bot-token="$TELEGRAM_TOKEN" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_PASS"
  unset GRAFANA_PASS

  # ArgoCD notifications with the same Telegram bot token
  seal_secret argocd-notifications-secret argocd \
    "$REPO_ROOT/k8s/bootstrap/argocd/sealed-secret.yaml" \
    --from-literal=telegram-token="$TELEGRAM_TOKEN"
  unset TELEGRAM_TOKEN
else
  warn "Skipped monitoring-secret and argocd-notifications-secret. Apply them manually."
fi

section "Step 8: Apply sealed secrets"
for f in \
  "$REPO_ROOT/k8s/apps/vaultwarden/sealed-secret.yaml" \
  "$REPO_ROOT/k8s/apps/cloudflared/sealed-secret.yaml" \
  "$REPO_ROOT/k8s/apps/immich/sealed-secret.yaml" \
  "$REPO_ROOT/k8s/apps/obsidian/sealed-secret.yaml" \
  "$REPO_ROOT/k8s/apps/monitoring/sealed-secret.yaml" \
  "$REPO_ROOT/k8s/bootstrap/argocd/sealed-secret.yaml"; do
  if grep -q "REPLACE_WITH_KUBESEAL_OUTPUT" "$f" 2>/dev/null; then
    warn "Skipping $f — not yet sealed (still has placeholder)."
  else
    kubectl apply -f "$f"
    info "Applied $f"
  fi
done

section "Step 9: Apply ArgoCD App-of-Apps"
kubectl apply -f "$REPO_ROOT/k8s/bootstrap/argocd/app-of-apps.yaml"
info "App-of-Apps applied. ArgoCD will now sync all apps from git."

section "Bootstrap complete!"
echo ""
echo "  KUBECONFIG=$KUBECONFIG_PATH"
echo ""
echo "  Next steps:"
echo "    1. git add k8s/apps/vaultwarden/sealed-secret.yaml \\"
echo "             k8s/apps/cloudflared/sealed-secret.yaml \\"
echo "             k8s/apps/immich/sealed-secret.yaml \\"
echo "             k8s/apps/obsidian/sealed-secret.yaml \\"
echo "             k8s/apps/monitoring/sealed-secret.yaml \\"
echo "             k8s/bootstrap/argocd/sealed-secret.yaml"
echo "    2. git commit -m 'chore: seal secrets'"
echo "    3. git push origin <branch>"
echo "    4. ArgoCD will sync vaultwarden, immich, cloudflared automatically."
echo ""
echo "  To persist KUBECONFIG in your shell:"
echo "    echo 'export KUBECONFIG=$KUBECONFIG_PATH' >> ~/.zshrc"
echo ""
info "Done!"
