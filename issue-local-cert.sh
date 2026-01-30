#!/bin/bash
set -euo pipefail

# =============================================================================
# nginx-cert-provisioner
# Automates local CA certificate issuance and Nginx reverse proxy configuration
# =============================================================================

# === CONFIGURATION ===========================================================
CA_DIR="/etc/local-ca"
ISSUED_DIR="$CA_DIR/issued"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
DAYS_VALID=825
COUNTRY="US"
STATE="Homelab"
ORG="Slade Services"

# === PREFLIGHT CHECKS ========================================================

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Validate CA files exist
if [[ ! -f "$CA_DIR/rootCA.crt.pem" ]]; then
    echo "Error: CA certificate not found at $CA_DIR/rootCA.crt.pem"
    exit 1
fi

if [[ ! -f "$CA_DIR/private/rootCA.key.pem" ]]; then
    echo "Error: CA private key not found at $CA_DIR/private/rootCA.key.pem"
    exit 1
fi

# === INPUT ===================================================================

usage() {
    echo "Usage: $0 [OPTIONS] [domain] [proxy_pass]"
    echo ""
    echo "Options:"
    echo "  -d, --domain <domain>   Domain/server_name (e.g., uptimekuma.local)"
    echo "  -p, --proxy <target>    Proxy pass target (e.g., http://10.0.0.50:3001)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                              # Interactive mode"
    echo "  $0 uptimekuma.local http://10.0.0.50:3001       # Positional args"
    echo "  $0 -d uptimekuma.local -p http://10.0.0.50:3001 # Flags"
    exit 0
}

DOMAIN=""
PROXY_PASS=""

# Parse arguments
if [[ $# -eq 0 ]]; then
    # Interactive mode
    read -rp "Enter domain/server_name (e.g., uptimekuma.local): " DOMAIN
    read -rp "Enter proxy_pass target (e.g., http://10.0.0.50:3001): " PROXY_PASS
elif [[ "$1" =~ ^[^-] ]]; then
    # Positional arguments
    DOMAIN="${1:-}"
    PROXY_PASS="${2:-}"
else
    # Flag-based arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) DOMAIN="$2"; shift 2 ;;
            -p|--proxy)  PROXY_PASS="$2"; shift 2 ;;
            -h|--help)   usage ;;
            *) echo "Error: Unknown option: $1"; echo ""; usage ;;
        esac
    done
fi

# Validate required inputs
if [[ -z "$DOMAIN" || -z "$PROXY_PASS" ]]; then
    echo "Error: Domain and proxy_pass are required."
    echo ""
    usage
fi

# Prepend protocol if missing
if [[ ! "$PROXY_PASS" =~ ^http ]]; then
    PROXY_PASS="http://$PROXY_PASS"
fi

# === DERIVED PATHS ===========================================================
CERT_DIR="$ISSUED_DIR/$DOMAIN"
NGINX_CONFIG="$NGINX_SITES_AVAILABLE/$DOMAIN"
ENABLED_LINK="$NGINX_SITES_ENABLED/$DOMAIN"

# === OVERWRITE CHECK =========================================================
if [[ -e "$CERT_DIR/$DOMAIN.crt.pem" || -e "$CERT_DIR/$DOMAIN.key.pem" ]]; then
    echo "Warning: A certificate for $DOMAIN already exists."
    read -rp "Do you want to overwrite it? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi
fi

# === GENERATE CERTIFICATE ====================================================
mkdir -p "$CERT_DIR"
cd "$CERT_DIR" || exit 1

echo "Generating private key..."
openssl genrsa -out "$DOMAIN.key.pem" 2048

echo "Generating CSR..."
openssl req -new -key "$DOMAIN.key.pem" \
    -out "$DOMAIN.csr.pem" \
    -subj "/C=$COUNTRY/ST=$STATE/O=$ORG/CN=$DOMAIN"

echo "Signing certificate with local CA..."
openssl x509 -req -in "$DOMAIN.csr.pem" \
    -CA "$CA_DIR/rootCA.crt.pem" \
    -CAkey "$CA_DIR/private/rootCA.key.pem" \
    -CAcreateserial \
    -out "$DOMAIN.crt.pem" \
    -days "$DAYS_VALID" -sha256 \
    -extensions v3_req \
    -extfile <(cat <<EOF
[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF
)

# Clean up CSR (no longer needed)
rm -f "$DOMAIN.csr.pem"

# === CREATE NGINX CONFIG =====================================================
echo "Writing Nginx config to: $NGINX_CONFIG"

cat > "$NGINX_CONFIG" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    # SSL Certificate
    ssl_certificate     $CERT_DIR/$DOMAIN.crt.pem;
    ssl_certificate_key $CERT_DIR/$DOMAIN.key.pem;

    # SSL Hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass $PROXY_PASS/;

        # Proxy Headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket Support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# === ENABLE SITE =============================================================
if [[ -L "$ENABLED_LINK" || -e "$ENABLED_LINK" ]]; then
    echo "Existing config found in sites-enabled. Skipping symlink."
else
    ln -s "$NGINX_CONFIG" "$ENABLED_LINK"
    echo "Symlink created: $ENABLED_LINK"
fi

# === RELOAD NGINX ============================================================
echo "Testing and reloading Nginx..."
nginx -t && systemctl reload nginx

# === DONE ====================================================================
echo ""
echo "Done! Site available at https://$DOMAIN"
echo "  Cert:  $CERT_DIR/$DOMAIN.crt.pem"
echo "  Key:   $CERT_DIR/$DOMAIN.key.pem"
echo "  Nginx: $NGINX_CONFIG"
