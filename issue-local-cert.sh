#!/bin/bash

# === CONFIGURATION ===
CA_DIR="/etc/local-ca"
ISSUED_DIR="$CA_DIR/issued"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
DAYS_VALID=825
COUNTRY="US"
STATE="Homelab"
ORG="Slade Services"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

# === INPUT ===
read -rp "Enter domain/server_name (e.g., uptimekuma.local): " DOMAIN
read -rp "Enter proxy_pass target (e.g., http://10.0.0.50:3001): " PROXY_PASS

if [[ -z "$DOMAIN" || -z "$PROXY_PASS" ]]; then
  echo " ^}^l Domain and proxy_pass are required."
  exit 1
fi

# Prepend protocol if missing
if [[ ! "$PROXY_PASS" =~ ^http ]]; then
  PROXY_PASS="http://$PROXY_PASS"
fi

CERT_DIR="$ISSUED_DIR/$DOMAIN"
NGINX_CONFIG="$NGINX_SITES_AVAILABLE/$DOMAIN"
ENABLED_LINK="$NGINX_SITES_ENABLED/$DOMAIN"

# === OVERWRITE WARNING IF CERT EXISTS ===
if [[ -e "$CERT_DIR/$DOMAIN.crt.pem" || -e "$CERT_DIR/$DOMAIN.key.pem" ]]; then
  echo " ^z   ^o  A certificate for $DOMAIN already exists."
  read -rp "Do you want to overwrite it? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo " ^}^l Aborting."
    exit 1
  fi
fi

# === CREATE CERT DIR ===
mkdir -p "$CERT_DIR"
cd "$CERT_DIR" || exit 1

# === GENERATE KEY AND CSR ===
echo " ^=^t^p Generating private key..."
openssl genrsa -out "$DOMAIN.key.pem" 2048

echo " ^=^s^d Generating CSR..."
openssl req -new -key "$DOMAIN.key.pem" \
  -out "$DOMAIN.csr.pem" \
  -subj "/C=$COUNTRY/ST=$STATE/O=$ORG/CN=$DOMAIN"

# === SIGN CERT ===
echo " ^|^m  ^o  Signing certificate with local CA..."
openssl x509 -req -in "$DOMAIN.csr.pem" \
  -CA "$CA_DIR/rootCA.crt.pem" \
  -CAkey "$CA_DIR/private/rootCA.key.pem" \
  -CAcreateserial \
  -out "$DOMAIN.crt.pem" \
  -days $DAYS_VALID -sha256 \
  -extensions v3_req \
  -extfile <(cat <<EOF
[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF
)

# === CREATE NGINX CONFIG ===
echo " ^=^l^p Writing Nginx config to: $NGINX_CONFIG"

cat > "$NGINX_CONFIG" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/$DOMAIN.crt.pem;
    ssl_certificate_key $CERT_DIR/$DOMAIN.key.pem;

    location / {
        proxy_pass $PROXY_PASS/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# === SYMLINK TO SITES-ENABLED ===
if [[ -L "$ENABLED_LINK" || -e "$ENABLED_LINK" ]]; then
    echo " ^=^t^a Existing link or file found in sites-enabled. Skipping symlink."
else
    ln -s "$NGINX_CONFIG" "$ENABLED_LINK"
    echo " ^|^e Symlink created: $ENABLED_LINK"
fi

# === RELOAD NGINX ===
echo " ^=^t^d Testing and reloading Nginx..."
nginx -t && systemctl reload nginx

# === DONE ===
echo ""
echo " ^=^n^i Done! Site available at https://$DOMAIN"
echo "   ^=^t^r Cert:  $CERT_DIR/$DOMAIN.crt.pem"
echo "   ^=^t^q Key:   $CERT_DIR/$DOMAIN.key.pem"
echo "   ^=^l^p Nginx: $NGINX_CONFIG"