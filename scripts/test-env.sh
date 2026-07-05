#!/usr/bin/env bash
# Throwaway k3s test env (proxmox/tofu/test-env). Usage: {up|down|status|verify}
# Full e2e sequence: see "E2E Test Environment" in README.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/proxmox/tofu/test-env"
TF="tofu -chdir=$TF_DIR"
VAR_FILE="../variables.auto.tfvars"
SSH_KEY="${K3S_SSH_KEY:-$HOME/.ssh/k3s_cluster}"

tf_init() { $TF init -input=false >/dev/null; }

up() {
  tf_init
  $TF apply -input=false -auto-approve -var-file="$VAR_FILE"

  control_ip=$($TF output -raw control_ip)
  echo "Waiting for SSH on test nodes..."
  for ip in $(grep -o 'ansible_host=[0-9.]*' "$REPO_ROOT/proxmox/ansible/test-inventory.ini" | cut -d= -f2); do
    for i in $(seq 1 30); do
      if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
          "debian@$ip" "echo up" &>/dev/null; then
        echo "READY: $ip"
        break
      fi
      [[ $i -eq 30 ]] && { echo "ERROR: $ip not reachable after 5m"; exit 1; }
      sleep 10
    done
  done
  echo "Test env up. Inventory: proxmox/ansible/test-inventory.ini"
}

down() {
  tf_init
  $TF destroy -input=false -auto-approve -var-file="$VAR_FILE"
  rm -f "$REPO_ROOT/proxmox/ansible/test-inventory.ini"
  echo "Test env down."
}

status() {
  tf_init
  $TF state list 2>/dev/null || echo "no state (env is down)"
}

verify() {
  control_ip=$($TF output -raw control_ip)
  expected=$($TF output -raw node_count)
  ready=0
  for i in $(seq 1 30); do
    # || true: transient ssh/kubectl failures must retry, not kill the loop via set -e
    ready=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "debian@$control_ip" \
      "sudo k3s kubectl get nodes --no-headers 2>/dev/null" | awk '$2=="Ready"' | wc -l | tr -d ' ' || true)
    if [[ "$ready" -eq "$expected" ]]; then
      echo "VERIFY OK: $ready/$expected nodes Ready"
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "debian@$control_ip" "sudo k3s kubectl get nodes"
      return 0
    fi
    sleep 10
  done
  echo "VERIFY FAILED: $ready/$expected nodes Ready after 5m"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "debian@$control_ip" "sudo k3s kubectl get nodes" || true
  return 1
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  verify) verify ;;
  *) echo "Usage: $0 {up|down|status|verify}"; exit 1 ;;
esac
