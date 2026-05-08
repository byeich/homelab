# Architecture

## Physical Infrastructure

Two Proxmox hosts and a separate TrueNAS storage server on a flat `10.0.0.0/24` home network. OpenTofu provisions all VMs declaratively; Ansible configures them. `homelab2` is the primary node (runs control plane + most workers); `homelab` hosts the two workers with large Longhorn disks.

```mermaid
flowchart TB
    subgraph prox2["Proxmox · homelab2"]
        pihole["pihole\nLXC"]
        ctrl1["k3s-control-1"]
        ctrl2["k3s-control-2"]
        ctrl3["k3s-control-3"]
        wrk1["k3s-worker-1\n50 GB disk"]
        wrk2["k3s-worker-2\n50 GB disk"]
        wrk3["k3s-worker-3\n50 GB disk"]
    end

    subgraph prox1["Proxmox · homelab"]
        wrk4["k3s-worker-4\n100 GB disk"]
        wrk5["k3s-worker-5\n100 GB disk"]
    end

    truenas[("TrueNAS SCALE\n10.0.0.9")]

    subgraph legend["Legend"]
        direction LR
        lc["Control plane"]:::control
        lw["Worker"]:::worker
        ld["DNS"]:::dns
        ls[("Storage")]:::nas
    end

    ctrl1 <-->|"etcd"| ctrl2
    ctrl2 <-->|"etcd"| ctrl3
    ctrl1 <-->|"etcd"| ctrl3
    wrk1 & wrk2 & wrk3 & wrk4 & wrk5 -->|"join"| ctrl1

    classDef control fill:#326ce5,stroke:#fff,stroke-width:2px,color:#fff
    classDef worker  fill:#6ea6e0,stroke:#fff,stroke-width:2px,color:#fff
    classDef dns     fill:#e85d04,stroke:#fff,stroke-width:2px,color:#fff
    classDef nas     fill:#e8a838,stroke:#fff,stroke-width:2px,color:#fff

    class ctrl1,ctrl2,ctrl3,lc control
    class wrk1,wrk2,wrk3,wrk4,wrk5,lw worker
    class pihole,ld dns
    class truenas,ls nas
```

| Host | IP | Role | Proxmox node | vCPU | RAM | Longhorn disk |
|---|---|---|---|---|---|---|
| `pihole` | `10.0.0.53` | Pi-hole DNS (LXC) | homelab2 | 1 | 512 MB | — |
| `k3s-control-1` | `10.0.0.60` | Control plane | homelab2 | 2 | 4 GB | 50 GB |
| `k3s-control-2` | `10.0.0.61` | Control plane | homelab2 | 2 | 4 GB | 50 GB |
| `k3s-control-3` | `10.0.0.62` | Control plane | homelab2 | 2 | 4 GB | 50 GB |
| `k3s-worker-1` | `10.0.0.70` | Worker | homelab2 | 2 | 4 GB | 50 GB |
| `k3s-worker-2` | `10.0.0.71` | Worker | homelab2 | 2 | 4 GB | 50 GB |
| `k3s-worker-3` | `10.0.0.72` | Worker | homelab2 | 2 | 4 GB | 50 GB |
| `k3s-worker-4` | `10.0.0.73` | Worker | homelab | 2 | 4 GB | 100 GB |
| `k3s-worker-5` | `10.0.0.74` | Worker | homelab | 2 | 4 GB | 100 GB |
| TrueNAS | `10.0.0.9` | NAS / backup target | bare metal | — | — | 2×12 TB mirror + spare |

> **HA note:** Workers currently connect to `ctrl1`'s API server directly (`10.0.0.60:6443`). etcd tolerates losing one control plane node, but workers lose API connectivity if ctrl1 goes down. A kube-vip VIP in front of all three control plane nodes is a planned improvement.

## k3s Cluster Services

Workloads are managed by ArgoCD via GitOps. Traefik is the ingress controller; Cloudflared maintains an outbound tunnel to Cloudflare so external traffic never requires open router ports. Longhorn provides distributed block storage; Immich photos bypass Longhorn and mount directly from TrueNAS over NFS.

```mermaid
flowchart TB
    cf(["☁️ Cloudflare"])
    tg(["📱 Telegram"])

    subgraph cluster["k3s Cluster"]
        subgraph ingress["Ingress"]
            cfpod["cloudflared"]
            traefik["Traefik"]
        end

        subgraph apps["Applications"]
            vw["Vaultwarden\npassword manager"]
            immich["Immich\nphoto library"]
            home["Homepage\ndashboard"]
            obs["Obsidian / CouchDB\nnotes sync"]
        end

        subgraph observability["Observability"]
            prom[("Prometheus")]
            grafana["Grafana"]
            alert["Alertmanager"]
        end

        lh[("Longhorn\n2 replicas · daily backup")]
    end

    truenas[("TrueNAS NFS\n10.0.0.9")]

    cf <-->|"tunnel"| cfpod
    cfpod --> traefik
    traefik --> vw & immich & home & obs & grafana

    vw & obs --> lh
    immich --> lh
    prom & grafana --> lh
    prom -.->|"scrapes metrics"| vw & immich & home & obs

    immich -.->|"photos NFS  (bypasses Longhorn)"| truenas
    lh -.->|"volume backups"| truenas

    alert -->|"alerts"| tg

    classDef k8s     fill:#326ce5,stroke:#fff,stroke-width:2px,color:#fff
    classDef storage fill:#e8a838,stroke:#fff,stroke-width:2px,color:#fff
    classDef ext     fill:#f5f5f5,stroke:#bbb,color:#444
    classDef msg     fill:#2ca5e0,stroke:#fff,stroke-width:2px,color:#fff

    class cfpod,traefik,vw,immich,home,obs,prom,grafana,alert k8s
    class lh,truenas storage
    class cf ext
    class tg msg
```

## Network & Traffic Flow

External services are exposed through a Cloudflare tunnel — no ports opened on the router. The Cloudflared pod maintains a persistent outbound connection; Cloudflare proxies `*.bkylab.net` traffic inbound through it. Internal access uses Pi-hole DNS records that resolve `*.bkylab.net` to `10.0.0.60`, hitting Traefik directly without leaving the LAN.

```mermaid
flowchart LR
    user(["👤 User"])

    subgraph ext["External"]
        cf["☁️ Cloudflare"]
    end

    subgraph home["Home Network · 10.0.0.0/24"]
        pihole["Pi-hole\n10.0.0.53"]

        subgraph cluster["k3s Cluster"]
            cfpod["cloudflared\n(tunnel)"]
            traefik["Traefik\n(ingress)"]
            svc["Service pods"]
        end
    end

    user -->|"public  *.bkylab.net"| cf
    cf <-->|"persistent tunnel"| cfpod
    cfpod --> traefik

    user -->|"LAN DNS lookup"| pihole
    pihole -.->|"resolves → 10.0.0.60"| user
    user -->|"→ 10.0.0.60 direct"| traefik

    traefik --> svc

    classDef k8s fill:#326ce5,stroke:#fff,stroke-width:2px,color:#fff
    classDef dns fill:#e85d04,stroke:#fff,stroke-width:2px,color:#fff
    classDef ext fill:#f5f5f5,stroke:#bbb,color:#444

    class cfpod,traefik,svc k8s
    class pihole dns
    class cf ext
```

**Public** (Cloudflare tunnel): `home.bkylab.net`, `obsidian.bkylab.net`, `grafana.bkylab.net`

**LAN-only** (Pi-hole DNS → `10.0.0.60`): `argocd.bkylab.net`, `longhorn.bkylab.net`

## GitOps Pipeline

ArgoCD polls the `main` branch and syncs any drift within ~3 minutes. All feature work goes to `dev` first — ArgoCD apps target `dev` during development. Renovate runs as a GitHub App and opens automated PRs for Helm chart, container image, and GitHub Actions version bumps; `renovate.json` blocks major upgrades for Longhorn and PostgreSQL which need manual procedures.

```mermaid
flowchart LR
    dev(["💻 Dev machine"])
    renovate(["🤖 Renovate"])
    tg(["📱 Telegram"])

    subgraph gh["GitHub"]
        ci["CI\nyamllint · tofu validate\nansible-lint · kubeconform"]
        devbr["dev branch"]
        repo["main branch"]
    end

    subgraph cluster["k3s Cluster"]
        argo["ArgoCD"]
        workloads["Workloads"]
    end

    dev -->|"git push"| devbr
    renovate -->|"dep bump PRs"| repo
    devbr -->|"PR + merge"| repo
    ci --> repo
    repo -->|"polls · ~3 min"| argo
    argo --> workloads
    argo -->|"sync · health alerts"| tg

    classDef k8s     fill:#326ce5,stroke:#fff,stroke-width:2px,color:#fff
    classDef ext     fill:#f5f5f5,stroke:#bbb,color:#444
    classDef msg     fill:#2ca5e0,stroke:#fff,stroke-width:2px,color:#fff

    class argo,workloads k8s
    class dev,renovate ext
    class tg msg
```

CI runs on every push and PR:
- **yamllint** — YAML syntax and style on `k8s/` and Ansible files
- **tofu validate + fmt** — Terraform syntax and formatting
- **ansible-lint** — Ansible best practices
- **kubeconform** — validates Kubernetes manifests against upstream schemas

## Storage Architecture

Storage is layered: Longhorn provides distributed block storage for most workloads; Immich photos use a direct NFS mount to TrueNAS to avoid routing bulk media storage through the cluster. Longhorn takes daily volume backups to TrueNAS over NFS, and TrueNAS syncs everything offsite to Backblaze B2 via rclone with client-side encryption.

```mermaid
flowchart TB
    subgraph cluster["k3s Cluster"]
        apps["Stateful apps\nvaultwarden · obsidian · grafana · postgres"]
        immich["Immich"]
        lh[("Longhorn\n2 replicas · daily backup · weekly snapshot")]
    end

    truenas[("TrueNAS · 10.0.0.9\nbigtank pool")]
    b2["☁️ Backblaze B2\n(rclone crypt)"]
    tofu(["💻 OpenTofu"])

    apps    -->|"PVC  RWO block"| lh
    immich  -->|"PVC  RWO block  (DB · cache)"| lh
    immich  -.->|"photos  NFS RWX"| truenas
    lh      -->|"volume backups  NFS"| truenas
    truenas -->|"Cloud Sync  --fast-list"| b2
    tofu    -->|"remote state  S3"| b2

    classDef k8s     fill:#326ce5,stroke:#fff,stroke-width:2px,color:#fff
    classDef storage fill:#e8a838,stroke:#fff,stroke-width:2px,color:#fff
    classDef ext     fill:#f5f5f5,stroke:#bbb,color:#444

    class apps,immich k8s
    class lh,truenas storage
    class b2,tofu ext
```

**StorageClass:**
- `longhorn-retain` — Vaultwarden, Immich-postgres, Obsidian. `reclaimPolicy: Retain` survives accidental namespace deletion.
- `longhorn` (Delete) — monitoring stack. Acceptable to reprovision on cluster rebuild.

**B2 cost:** `--fast-list` batches LIST calls into Class B operations, staying under the 2,500/day Class C free-tier cap.
