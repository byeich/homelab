# Disaster Recovery Runbook

Covers full cluster rebuild from scratch, restoring all stateful data. For initial fresh setup, see README.md.

> **Personal runbook** — environment-specific to this homelab. IPs, volume names, and credential locations are hardcoded for this setup. Local machine commands assume macOS.

**Estimated recovery times:**
| Scenario | Time |
|---|---|
| k3s cluster only (VMs intact) | ~45 min |
| Full cluster rebuild (VMs gone, TrueNAS intact) | ~90 min |
| Full disaster including B2 restore | ~2–3 hours |

Longhorn volume restores (Step 7) are the main variable — large volumes over a slow NFS link take longer.

## Pre-requisites

Before starting, verify access to:

- **Bitwarden** (bitwarden.com or mobile app — NOT vaultwarden.bkylab.net, which is the service being rebuilt) — contains the sealed-secrets key backup, rclone B2 crypt passphrase/salt, Cloudflare tunnel credentials.json, and all service passwords
- **B2 credentials** — `~/.config/homelab/tofu.env` (or retrieve B2 Key ID + App Key from Bitwarden for tofu remote state)
- **SSH keys** — `~/.ssh/homelab` (Pi-hole LXC) and `~/.ssh/k3s_cluster` (k3s VMs). Run `./scripts/generate-keys.sh` if missing
- **CLI tools** — `kubectl`, `helm`, `tofu`, `rclone`, `kubeseal` (`brew install kubeseal` if missing — needed for Step 5 smoke test)
- **Proxmox** running with VM templates on both nodes (ID 9000 on homelab2, ID 9001 on homelab)
- **TrueNAS** running with NFS shares accessible (Longhorn backup target + Immich photos NFS)

## Scenario

| Scenario | Start at |
|---|---|
| k3s cluster gone, Proxmox + TrueNAS intact, VMs still exist | Step 3 (Pi-hole LXC still running) |
| k3s cluster gone, Proxmox + TrueNAS intact, VMs gone | Step 1 |
| Proxmox nodes gone | Step 1 |
| TrueNAS also gone (full disaster) | Step 0 |

---

## Step 0: Restore from B2 (only if TrueNAS lost)

> Skip this step if TrueNAS is running — Longhorn reads the NFS backup share directly and the rclone passphrase is not needed.

TrueNAS itself must be rebuilt first (OS reinstall, pool import, datasets recreated) before restoring data to it. Once the OS and pool are up:

```bash
brew install rclone

# Configure rclone — need a b2 remote + a crypt remote layered on top of it.
# Get the passphrase + salt from Bitwarden → TrueNAS admin login entry.
# When prompted for remote names: name the b2 remote "b2homelab", name the crypt remote "b2crypt"
# (the sync commands below use "b2crypt:" — if you name it differently, update the commands)
rclone config   # create b2 remote (type: b2), then a crypt remote (type: crypt) pointing at b2homelab:homelab-backups-bky

# Verify the actual path structure before restoring — paths depend on how the crypt remote was configured
rclone ls b2crypt: --max-depth 2

# Dry run first to confirm what would be restored
# If the crypt remote points at b2homelab:homelab-backups-bky, paths are relative to that root:
rclone sync --dry-run b2crypt:backups /mnt/bigtank/backups
rclone sync --dry-run b2crypt:immich_data /mnt/bigtank/immich_data

# Restore (expect ~80GB total, will take a while)
rclone sync b2crypt:backups /mnt/bigtank/backups
rclone sync b2crypt:immich_data /mnt/bigtank/immich_data
```

After TrueNAS NFS shares are restored, continue from Step 1.

---

## Step 1: Provision VMs (tofu apply)

```bash
cd proxmox/tofu
source ~/.config/homelab/tofu.env   # B2 credentials for remote state
tofu init                            # required on fresh checkout or new machine
tofu apply
```

`tofu apply` provisions all VMs + the Pi-hole LXC and regenerates `proxmox/ansible/inventory.ini` from live state.

---

## Step 2: Install Pi-hole DNS

Install Pi-hole **before** k3s. The k3s VMs are configured to use 10.0.0.53 as their DNS resolver — if Pi-hole isn't running when k3s pulls images in Step 3, DNS resolution fails.

```bash
cd proxmox/ansible
./run-playbook.sh playbooks/baseline.yml
./run-playbook.sh playbooks/pihole.yml
```

Verify Pi-hole is resolving before proceeding:
```bash
dig @10.0.0.53 google.com +short   # should return an IP, not an error
```

Pi-hole at 10.0.0.53. Internal hostnames (`argocd.bkylab.net`, `longhorn.bkylab.net`) resolve via Pi-hole → 10.0.0.60 (Traefik).

---

## Step 3: Install k3s cluster

```bash
cd proxmox/ansible

# Install k3s on control + worker nodes (~15 min)
./run-playbook.sh playbooks/k3s.yml --private-key ~/.ssh/k3s_cluster

# Prepare Longhorn disks on workers (installs open-iscsi, cryptsetup, loads dm_crypt)
./run-playbook.sh playbooks/k3s_disk_prep.yml --private-key ~/.ssh/k3s_cluster
```

Copy kubeconfig and verify cluster:
```bash
mkdir -p ~/.kube
# StrictHostKeyChecking=no required — freshly provisioned VMs have new host keys
ssh -i ~/.ssh/k3s_cluster -o StrictHostKeyChecking=no debian@10.0.0.60 \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's|https://127.0.0.1:6443|https://10.0.0.60:6443|g' \
  > ~/.kube/k3s-homelab.yaml
chmod 600 ~/.kube/k3s-homelab.yaml
export KUBECONFIG=~/.kube/k3s-homelab.yaml

kubectl get nodes   # all 8 nodes should be Ready
```

---

## Step 4: Install infrastructure (Helm charts)

This is a rebuild — sealed secrets are already committed to git. Install the Helm charts directly, then restore the sealed-secrets key before letting ArgoCD sync.

> **Why not `k3s_bootstrap.yml`?** The README rebuild path uses that playbook, but it runs all the way through Helm installs → sealed-secrets apply → App-of-Apps in one shot. For DR, the sealed-secrets key must be manually restored (Step 5) between Helm install and App-of-Apps — there's no safe place to inject that step inside the playbook. Do the Helm installs manually here, restore the key in Step 5, then apply App-of-Apps in Step 6.

```bash
export KUBECONFIG=~/.kube/k3s-homelab.yaml
REPO_ROOT=$(git rev-parse --show-toplevel)

helm repo add argo https://argoproj.github.io/argo-helm
helm repo add longhorn https://charts.longhorn.io
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.9.1 \
  --values "$REPO_ROOT/k8s/bootstrap/argocd/values.yaml" \
  --wait

kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.7.3 \
  --wait --timeout 10m
# Note: Longhorn backup target and settings are applied by ArgoCD in Step 6.
# Verify backup target is set before starting Step 7.

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --version 2.18.5 \
  --set fullnameOverride=sealed-secrets-controller \
  --wait
```

Version numbers are pinned in `scripts/bootstrap.sh` — use those as the source of truth if this runbook is out of date.

**Do NOT apply App-of-Apps yet.** Continue to Step 5.

---

## Step 5: CRITICAL — Restore sealed-secrets key

The sealed-secrets controller auto-generates a new key pair on first startup. If ArgoCD syncs before you replace it with the original backed-up key, every SealedSecret in git will fail to decrypt — the controller returns an error and creates no Secret at all, so every service starts with missing credentials.

```bash
# 1. Get the backed-up key YAML from Bitwarden
#    Bitwarden → Secure Notes → "sealed-secrets-keykwwrf full YAML"
#    Save it locally — do NOT commit this file
vim ~/sealed-secrets-keykwwrf.yaml

# 2. Delete the auto-generated key the controller created on startup
kubectl delete secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active

# 3. Apply the backed-up key
kubectl apply -f ~/sealed-secrets-keykwwrf.yaml

# 4. Restart the controller so it loads the restored key
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
kubectl rollout status deployment/sealed-secrets-controller -n kube-system

# 5. Verify — should show the original keykwwrf secret, not a new auto-generated name
kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key

# 6. Smoke test — validate a SealedSecret from the local git file (not from the cluster,
#    since app-of-apps hasn't been applied yet and no SealedSecrets exist in the cluster)
kubeseal --validate \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  < k8s/apps/vaultwarden/sealed-secret.yaml
# "OK" means the key works. Any error means the wrong key was restored — stop and investigate.
# Common causes: incomplete YAML pasted (check that both tls.crt and tls.key fields are present),
# or wrong Bitwarden note (verify it contains "sealed-secrets-keykwwrf" in the name field).

# 7. Clean up the plaintext key file
rm ~/sealed-secrets-keykwwrf.yaml
```

---

## Step 6: Apply App-of-Apps (ArgoCD syncs everything)

```bash
export KUBECONFIG=~/.kube/k3s-homelab.yaml   # re-export if you opened a new terminal
kubectl apply -f k8s/bootstrap/argocd/app-of-apps.yaml
```

ArgoCD will sync all apps from git. Expected state immediately after:
- Namespaces, services, and most pods will come up healthy
- **The following PVCs will stay `Pending`** — this is normal, the volumes don't exist yet:
  - `vaultwarden/vaultwarden-data` → resolved in Step 7 by restoring Longhorn backup + creating static PV
  - `immich/immich-postgres` → resolved in Step 7 by restoring Longhorn backup + creating static PV
  - `immich/immich-model-cache` → resolved in Step 7 by removing the volumeName pin (no restore needed)
  - `obsidian/obsidian-data` → resolved in Step 7 by removing the volumeName pin (no restore needed)
- **Pods depending on those PVCs will also be Pending** — expected

Check sync and Longhorn backup target before proceeding to Step 7:
```bash
# ArgoCD sync status
kubectl get applications -n argocd

# Confirm Longhorn backup target is set (ArgoCD must have synced longhorn settings first)
kubectl get settings.longhorn.io backup-target -n longhorn-system -o jsonpath='{.spec.value}'
# Should output: nfs://10.0.0.9:/mnt/bigtank/backups/longhorn
```

---

## Step 7: Restore stateful data

### What to restore (and what to skip)

| PVC | Restore? | Reason |
|---|---|---|
| `vaultwarden-data` | ✅ Longhorn backup | Contains SQLite DB + nightly dumps |
| `immich-postgres` | ✅ Longhorn backup (preferred) or Immich SQL dump | See alternatives below |
| `immich-model-cache` | ⚠️ Remove volumeName pin | PVC has a volumeName pin — pod stays Pending forever without a matching PV. Remove the pin so Longhorn provisions a fresh empty volume; models re-download on first ML request |
| `obsidian-data` | ⚠️ Remove volumeName pin | Same issue — pod stays Pending without a matching PV. Remove pin, let Longhorn provision fresh, LiveSync re-uploads from local vault |

### Restore a volume from Longhorn backup

Repeat for each PVC that needs data (`vaultwarden-data`, `immich-postgres`).

**1. Verify backup target is reachable** — Longhorn UI → `longhorn.bkylab.net` → Settings → confirm Backup Target shows `nfs://10.0.0.9:/mnt/bigtank/backups/longhorn`. If not set yet, wait for ArgoCD to sync the longhorn app or set it manually.

NFS share on TrueNAS requires: Maproot User=root, Maproot Group=wheel, Network=10.0.0.0/24.

**2. Restore in Longhorn UI** → Backup → find the volume → Restore → name the restored volume to match the `volumeName` pin in the PVC spec in git:

| PVC | Restored volume name |
|---|---|
| `vaultwarden/vaultwarden-data` | `vaultwarden-data-restored` |
| `immich/immich-postgres` | `immich-postgres-restored` |

Wait for the restored volume to reach `Detached` state before continuing.

**3. Create a static PV** that points ArgoCD's waiting PVC at the restored volume. The `claimRef` field pre-binds this PV to the specific PVC so Longhorn doesn't dynamically provision a new empty volume instead.

For `vaultwarden`:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vaultwarden-data-restored
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-retain
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: vaultwarden-data-restored
  claimRef:
    name: vaultwarden-data
    namespace: vaultwarden
```

For `immich-postgres`:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-postgres-restored
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-retain
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: immich-postgres-restored
  claimRef:
    name: immich-postgres
    namespace: immich
```

Save each block to a temp file and apply:
```bash
kubectl apply -f /tmp/pv-vaultwarden.yaml
kubectl apply -f /tmp/pv-immich-postgres.yaml
```

**4. Delete the Pending PVC** so ArgoCD recreates it and it binds to the static PV above. ArgoCD's selfHeal will immediately recreate the PVC from git — this is expected and correct. The claimRef on the PV ensures the new PVC binds to the restored data, not a fresh empty volume.

```bash
kubectl delete pvc vaultwarden-data -n vaultwarden
# For immich:
kubectl delete pvc immich-postgres -n immich
```

**5. Verify** the PVC is Bound (not Pending):
```bash
kubectl get pvc -n vaultwarden
kubectl get pvc -n immich
```
If still Pending after ~30 seconds: `kubectl describe pvc vaultwarden-data -n vaultwarden` — common cause is a mismatch between the PV name, `volumeHandle`, or `claimRef` namespace/name and what's in the PVC spec.

### Alternative: Immich native postgres restore

Use this if the Longhorn backup for immich-postgres is unavailable or stale. Immich SQL dumps are stored in the upload directory on TrueNAS NFS (`/mnt/bigtank/immich_data/upload/backups/`) and survive cluster rebuilds independently of Longhorn.

1. Remove the `volumeName: immich-postgres-restored` pin from `k8s/apps/immich/pvc-postgres.yaml`, commit and push. ArgoCD will sync the change and Longhorn will provision a fresh empty postgres volume.
2. Wait for all Immich pods to be Running.
3. Immich UI → Administration → Maintenance → Restore from backup → select the most recent `.sql.gz`.
4. After restore: run `kubectl get pvc immich-postgres -n immich -o jsonpath='{.spec.volumeName}'` to get the new auto-generated volume name, update `volumeName` in `pvc-postgres.yaml` to pin it, commit and push.

### Obsidian and immich-model-cache (remove volumeName pin, reprovision fresh)

Both PVCs have `volumeName` pins pointing at volumes that no longer exist. Remove the pins so Longhorn can provision fresh empty volumes.

1. In `k8s/apps/obsidian/pvc.yaml` and `k8s/apps/immich/pvc-model-cache.yaml`, delete the `volumeName:` line from each.
2. Commit and push — ArgoCD will sync the change and Longhorn provisions fresh volumes.
3. Wait for pods to be Running.
4. **Obsidian**: Open Obsidian on Mac → Self-hosted LiveSync plugin detects the empty remote database → uploads the local vault automatically.
5. **immich-model-cache**: ML models re-download automatically on the first request to immich-machine-learning (takes a few minutes).
6. After both pods are stable, record the new auto-generated volume names and add them back as `volumeName` pins in each PVC yaml: `kubectl get pvc obsidian-data -n obsidian -o jsonpath='{.spec.volumeName}'`. Commit and push to pin the new volumes.

---

## Step 8: Verify

```bash
# Check cloudflared tunnel is connected first — all *.bkylab.net traffic goes through it
kubectl logs -n cloudflared -l app=cloudflared --tail=20
# Look for "Connection registered" or "Connected to Cloudflare"

# All pods running (Pending PVCs from Step 7 should now be Bound)
kubectl get pods -A | grep -Ev 'Running|Completed'

# All ArgoCD apps healthy
kubectl get applications -n argocd

# Services (only reachable once cloudflared is connected)
open https://vaultwarden.bkylab.net   # login with Bitwarden account credentials
open https://immich.bkylab.net        # credentials in Vaultwarden
open https://grafana.bkylab.net
```

---

## Appendix: Recovery without Longhorn backups

If Longhorn backups are lost or all backups captured empty volumes (silent backup failure — the backup reports success but the volume was always empty):

| Service | Recovery path | Data risk |
|---|---|---|
| Vaultwarden | Restore from the most recent manual export file (JSON/CSV) saved outside of Vaultwarden | Loses entries since last export |
| Immich (photos) | Photos on TrueNAS NFS survive. Create new admin account → Administration → Jobs → Scan All | Loses albums, faces, metadata unless postgres backup available |
| Immich (postgres) | SQL dumps at `/mnt/bigtank/immich_data/upload/backups/` on TrueNAS — restore via Immich Maintenance UI | Loses changes since last dump |
| Obsidian | Open Obsidian on Mac → LiveSync re-uploads | No data loss — local vault is source of truth |

**Verify backup health after rebuild** to catch silent empty-backup failure before the next incident:
```bash
# Vaultwarden — confirm backup files exist and are recent
kubectl exec -n vaultwarden deploy/vaultwarden -- ls -lh /data/

# Immich SQL dumps on TrueNAS — confirm non-empty and recent (run on TrueNAS shell)
ls -lh /mnt/bigtank/immich_data/upload/backups/
```

Check Longhorn backup sizes in the UI: Longhorn → Backup → each volume → Size column should be non-zero and growing over time.

---

## Reference

| Item | Location |
|---|---|
| Sealed-secrets key backup | Bitwarden → Secure Notes → "sealed-secrets-keykwwrf full YAML" |
| B2 rclone crypt passphrase + salt | Bitwarden → TrueNAS admin login entry |
| Cloudflare tunnel credentials.json | Bitwarden → "cloudflare tunnel a1c6f9ec" |
| B2 Key ID + App Key | `~/.config/homelab/tofu.env` or Bitwarden |
| Longhorn backup store | `nfs://10.0.0.9:/mnt/bigtank/backups/longhorn` |
| Immich SQL dumps | TrueNAS → `/mnt/bigtank/immich_data/upload/backups/` |
| Longhorn UI | `longhorn.bkylab.net` (local only, Pi-hole DNS → 10.0.0.60) |
| ArgoCD UI | `argocd.bkylab.net` (local only, Pi-hole DNS → 10.0.0.60) |
