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
  - `rootCA.crt.pem` - CA certificate
  - `private/rootCA.key.pem` - CA private key
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
| `ORG` | `Homelab Services` | Certificate organization |

## Output

For a domain like `uptimekuma.local`, the script creates:

```
/etc/local-ca/issued/uptimekuma.local/
├── uptimekuma.local.key.pem    # Private key
└── uptimekuma.local.crt.pem    # Signed certificate

/etc/nginx/sites-available/uptimekuma.local    # Nginx config
/etc/nginx/sites-enabled/uptimekuma.local      # Symlink
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.