# nginx-cert-provisioner

A bash script that automates local CA certificate issuance and Nginx reverse proxy configuration for homelab services.

## Features

- Generates certificates signed by your local Certificate Authority
- Creates Nginx reverse proxy configs with HTTPS redirect and HTTP/2
- SSL hardening (TLS 1.2/1.3, HSTS, session caching)
- WebSocket support for apps like Uptime Kuma, Portainer, etc.
- Interactive, positional, or flag-based argument modes
- CA file validation before execution
- Warns before overwriting existing certificates
- Automatically enables site and reloads Nginx

## Prerequisites

- A local CA already set up at `/etc/local-ca/` with:
  - `rootCA.crt` - CA certificate
  - `private/rootCA.key` - CA private key
- Nginx installed with `sites-available` and `sites-enabled` structure
- Root access

## Usage

```bash
# Interactive mode
sudo ./issue-local-cert.sh

# Positional arguments
sudo ./issue-local-cert.sh uptimekuma.local http://10.0.0.50:3001

# Flags
sudo ./issue-local-cert.sh -d uptimekuma.local -p http://10.0.0.50:3001
```

### Options

| Flag | Description |
|------|-------------|
| `-d, --domain` | Domain/server_name (e.g., `uptimekuma.local`) |
| `-p, --proxy` | Proxy pass target (e.g., `http://10.0.0.50:3001`) |
| `-h, --help` | Show help message |

## Configuration

Edit the variables at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `CA_DIR` | `/etc/local-ca` | Path to your local CA |
| `DAYS_VALID` | `825` | Certificate validity (825 = Apple max) |
| `COUNTRY` | `US` | Certificate country code |
| `STATE` | `Homelab` | Certificate state/province |
| `ORG` | `Slade Services` | Certificate organization |

## Output

For a domain like `uptimekuma.local`, the script creates:

```
/etc/local-ca/issued/uptimekuma.local/
├── uptimekuma.local.key    # Private key
└── uptimekuma.local.crt    # Signed certificate

/etc/nginx/sites-available/uptimekuma.local    # Nginx config
/etc/nginx/sites-enabled/uptimekuma.local      # Symlink
```

## Continuous Integration (Jenkins)

This repo includes a `Jenkinsfile` that lints and smoke-tests the script on every push. It expects:

- A worker node labeled `linux-worker` with `bash`, `git`, and passwordless `sudo` scoped to a couple of fixed helper scripts (see below) and to `issue-local-cert.sh` itself
- Two one-time helper scripts placed on the worker outside this repo (they're CI infrastructure, not part of the tool):
  - `/usr/local/bin/jenkins-nginx-cert-prereqs.sh` - installs `openssl`, `nginx`, `shellcheck`, and bootstraps a local CA if one doesn't already exist
  - `/usr/local/bin/jenkins-nginx-cert-cleanup.sh` - removes the throwaway test domain's cert and Nginx site after the optional issuance test

Pipeline stages: **Install Prerequisites** (idempotent, safe to rerun) → **Set Permissions** → **Lint** (`bash -n` + `shellcheck`) → **Smoke Test** (`--help`, non-destructive) → optional **Issuance Test**, gated behind a `RUN_ISSUANCE_TEST` build parameter, which actually runs the script against a throwaway domain and cleans up afterward.

The issuance test is opt-in rather than automatic on every push, since it writes a real cert and Nginx site config on the worker each time it runs.

## 📜 License

This project is licensed under the **[MIT License](LICENSE)** - feel free to use, modify, and distribute.

---
