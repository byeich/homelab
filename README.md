# homelab
Repo for IaC/configuration of homelab


## OpenTofu

All infrastructure is managed from `proxmox/tofu`.

**Setup (first time):**
1. Copy the example vars file: `cp variables.auto.tfvars.example variables.auto.tfvars`
2. Fill in `variables.auto.tfvars` with your Proxmox endpoint, API token, node name, and datastores
3. Run `tofu init` to download providers
4. Run `tofu plan` to preview changes
5. Run `tofu apply` to provision

`tofu apply` also generates `proxmox/ansible/inventory.ini` from the live VM state.

**What gets created:**

| Resource | IDs | Description |
|---|---|---|
| LXC: `pihole` | 303 | Pi-hole DNS container |
| VM: `k3s-control-1/2/3` | 310–312 | k3s control plane nodes |
| VM: `k3s-worker-1/2/3` | 320–322 | k3s worker nodes |

> VMs clone from Proxmox template ID 9000 — must be a Debian cloud-init image with `qemu-guest-agent` installed.

## Ansible Playbooks

Playbooks are run from the `proxmox/ansible` directory using `run-playbook.sh`:

```bash
cd proxmox/ansible
./run-playbook.sh playbooks/<playbook>.yml --private-key ~/.ssh/<key>
```

**Setup (first time):**
1. Create a vault password file: `echo "your-password" > .vault_pass && chmod 600 .vault_pass`
2. Create the vault with secrets: `ansible-vault create group_vars/all/vault.yml`
   - Add `k3s_token: "your-cluster-secret"` for k3s playbooks
3. `tofu apply` generates `inventory.ini` automatically from VM state

**Available playbooks:**

| Playbook | Hosts | Description |
|---|---|---|
| `playbooks/baseline.yml` | `lxc_host` | Base packages and SSH for LXC containers |
| `playbooks/pihole.yml` | `pihole` | Pi-hole DNS install and configuration |
| `playbooks/k3s.yml` | `k3s-control`, `k3s-workers` | k3s cluster setup (control plane + workers) |
| `playbooks/k3s_disk_prep.yml` | `k3s-workers` | Prepare extra disks for Longhorn storage |

**Examples:**
```bash
./run-playbook.sh playbooks/k3s.yml --private-key ~/.ssh/k3s_cluster
./run-playbook.sh playbooks/pihole.yml
./run-playbook.sh playbooks/baseline.yml --limit=pihole
```

## k3s Cluster Bootstrap

After VMs are provisioned and `k3s.yml` has run, use the bootstrap script to finish setting up the cluster:

```bash
./scripts/bootstrap.sh
```

This script (Mac-native, requires Homebrew) will:
1. Install `helm`, `kubectl`, and `kubeseal` if not already present
2. Copy the kubeconfig from the first control node (`10.0.0.60`)
3. Prompt for secret values and seal them with `kubeseal` (nothing written to disk in plaintext)
4. Install ArgoCD, Longhorn, and Sealed Secrets via Helm
5. Apply the sealed secrets and kick off the ArgoCD App-of-Apps

**Full rebuild flow:**
```bash
tofu apply                            # provision VMs
./run-playbook.sh playbooks/k3s.yml   # install k3s on all nodes
./run-playbook.sh playbooks/k3s_disk_prep.yml  # prep Longhorn disks on workers
./scripts/bootstrap.sh                # ArgoCD + Longhorn + secrets + app-of-apps
git push origin <branch>              # ArgoCD syncs all apps
```

> **Why Longhorn is installed via Helm and not ArgoCD:** Longhorn's pre-upgrade Helm hook requires a ServiceAccount that doesn't exist until the chart installs it. ArgoCD hits a chicken-and-egg failure on a fresh cluster. The bootstrap script installs it directly; ArgoCD then adopts and manages it going forward.

## GitOps (ArgoCD)

All Kubernetes workloads are managed via ArgoCD using the App-of-Apps pattern.

- App definitions: `k8s/apps/`
- Bootstrap manifests: `k8s/bootstrap/argocd/`
- Infrastructure configs (Longhorn recurring jobs, etc.): `k8s/infrastructure/`

**Services managed:**

| App | Namespace | Notes |
|---|---|---|
| Vaultwarden | `vaultwarden` | Password manager, RWO Longhorn PVC |
| Immich | `immich` | Photo library, photos on NFS (TrueNAS), DB on Longhorn |
| Cloudflared | `cloudflared` | Cloudflare tunnel — routes `vaultwarden.bkylab.net` and `immich.bkylab.net` |
| Longhorn | `longhorn-system` | Distributed block storage, daily backups + weekly snapshots |
| Sealed Secrets | `kube-system` | Encrypts secrets for safe git storage |

## Secrets

Secrets are managed with [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). Encrypted `SealedSecret` manifests are committed to git; the in-cluster controller decrypts them.

To re-seal a secret (e.g. after rotating a credential):
```bash
kubectl create secret generic <name> -n <namespace> \
  --from-literal=key=value \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --format yaml > k8s/apps/<app>/sealed-secret.yaml
```

Never commit plaintext secrets. Files matching `secrets-local/` and `*.plaintext.yaml` are gitignored.