# Architecture

## Physical Infrastructure

Two Proxmox hosts and a separate TrueNAS storage server on a flat 10.0.0.0/24 home network. OpenTofu provisions all VMs declaratively; Ansible configures them. `homelab2` is the primary node (runs control plane + most workers); `homelab` hosts the two workers with large Longhorn disks.

```mermaid
graph TB
    subgraph prox2["Proxmox: homelab2"]
        pihole["Pi-hole LXC · 10.0.0.53"]
        ctrl["k3s-control-1/2/3\n10.0.0.60 – 62  ·  4 GB RAM  ·  2 vCPU"]
        wrk123["k3s-worker-1/2/3\n10.0.0.70 – 72  ·  4 GB RAM  ·  50 GB Longhorn disk"]
    end

    subgraph prox1["Proxmox: homelab"]
        wrk45["k3s-worker-4/5\n10.0.0.73 – 74  ·  4 GB RAM  ·  100 GB Longhorn disk"]
    end

    truenas["TrueNAS SCALE · 10.0.0.9\nbigtank pool  (2 × 12 TB mirror + hot spare)\nFast pool  (SSD)"]
```

## Network & Traffic Flow

External services are exposed through a Cloudflare tunnel — no ports opened on the router. The Cloudflared pod inside the cluster maintains an outbound tunnel to Cloudflare, which proxies `*.bkylab.net` traffic inbound. Internal access uses Pi-hole DNS records that resolve `*.bkylab.net` to `10.0.0.60` (the first control node), hitting Traefik directly without leaving the LAN.

```mermaid
graph LR
    user(["User"])

    subgraph ext["External"]
        cf["Cloudflare\nDNS + CDN"]
    end

    subgraph home["Home Network"]
        pihole["Pi-hole · 10.0.0.53"]

        subgraph cluster["k3s Cluster"]
            cfpod["cloudflared pod\n(persistent tunnel)"]
            traefik["Traefik\n(ingress controller)"]
            svc["Service pods"]
        end
    end

    user -->|"*.bkylab.net  (public)"| cf
    cf <-->|"tunnel"| cfpod
    cfpod --> traefik

    user -->|"*.bkylab.net  (LAN)"| pihole
    pihole -->|"→ 10.0.0.60"| traefik

    traefik --> svc
```

**Public services** (Cloudflare tunnel): `home.bkylab.net`, `obsidian.bkylab.net`, `grafana.bkylab.net`

**LAN-only** (Pi-hole DNS only): `argocd.bkylab.net`, `longhorn.bkylab.net`

## GitOps Pipeline

All Kubernetes workloads are managed via ArgoCD using the App-of-Apps pattern. ArgoCD polls the `main` branch of this repo; changes merged to `main` are automatically synced to the cluster within ~3 minutes. Feature work targets the `dev` branch — ArgoCD apps point at `dev` for active development, with `main` as the stable target.

Renovate runs as a GitHub App and opens automated PRs for dependency bumps (Helm charts, container images, GitHub Actions). Version pinning rules in `renovate.json` block major upgrades for Longhorn and PostgreSQL, which require manual upgrade procedures.

```mermaid
graph LR
    dev(["Dev machine"])

    dev -->|"git push dev/main"| gh["GitHub"]
    renovate["Renovate bot"] -->|"dep bump PRs"| gh

    gh --> ci["CI pipeline\nyamllint · tofu validate\nansible-lint · kubeconform"]
    ci -->|"merge"| repo["main branch"]

    repo -->|"polls every 3 min"| argo["ArgoCD"]
    argo -->|"sync"| k3s["k3s cluster"]
    argo -->|"sync · health alerts"| tg["📱 Telegram"]
```

CI runs on every push and PR:
- **yamllint** — YAML syntax and style on `k8s/` and Ansible files
- **tofu validate + fmt** — Terraform syntax and formatting
- **ansible-lint** — Ansible best practices (37 violations fixed to reach clean baseline)
- **kubeconform** — validates Kubernetes manifests against upstream schemas (strict mode)

## Storage Architecture

Storage is layered: Longhorn provides distributed block storage for most workloads; Immich photos use a direct NFS mount to TrueNAS to avoid copying 100+ GB through the cluster. Longhorn takes daily volume backups to TrueNAS over NFS, and TrueNAS syncs everything offsite to Backblaze B2 via rclone with client-side encryption.

```mermaid
graph TB
    subgraph cluster["k3s Cluster"]
        apps["Stateful app pods\nvaultwarden · obsidian · grafana · postgres"]
        immich["Immich\n(server + machine learning)"]
        lh["Longhorn\n2 replicas · daily backup · weekly snapshot\nlonghorn-retain StorageClass"]
    end

    truenas["TrueNAS SCALE · 10.0.0.9\n/mnt/bigtank/longhorn-backups\n/mnt/bigtank/immich/photos"]
    b2["Backblaze B2\n(rclone crypt — filenames encrypted)"]
    tofu["OpenTofu\n(local machine)"]

    apps -->|"PVC  RWO block"| lh
    immich -->|"PVC  RWO block  (DB + cache)"| lh
    immich -->|"photos  NFS RWX\n(bypasses Longhorn)"| truenas
    lh -->|"volume backups  NFS"| truenas
    truenas -->|"Cloud Sync task\n--fast-list"| b2
    tofu -->|"remote state\nS3-compatible backend"| b2
```

**StorageClass notes:**
- `longhorn-retain` — used by Vaultwarden, Immich-postgres, Obsidian. `reclaimPolicy: Retain` so PVCs survive accidental namespace deletion.
- `longhorn` (Delete) — used by monitoring stack (Prometheus, Grafana, Alertmanager). Acceptable to lose and reprovision.

**B2 cost note:** `--fast-list` enabled on the TrueNAS Cloud Sync task to batch LIST operations into Class B calls, avoiding the 2,500/day Class C free-tier cap on large datasets.
