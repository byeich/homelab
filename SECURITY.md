# Security Policy

## Scope

This is a personal homelab repository. It contains infrastructure-as-code for a self-hosted Kubernetes cluster. No multi-user systems or third-party data are involved.

## Reporting a Vulnerability

If you spot a security issue (leaked credentials, misconfiguration, insecure patterns), please open a [GitHub issue](https://github.com/byeich/homelab/issues) or email directly.

Secrets are managed via [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) — encrypted manifests are safe to commit. If you believe an actual secret has been leaked, please report it privately rather than opening a public issue.

## What is intentionally public

- Cloudflare tunnel ID: the credentials file is gitignored and sealed separately
- Internal IP ranges and hostnames are fine as this is managing my homelab.
