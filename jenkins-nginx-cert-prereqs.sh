#!/bin/bash
# jenkins-nginx-cert-prereqs.sh
#
# One-time/idempotent CI bootstrap for the Nginx-Cert-Provisioner Jenkins pipeline.
# Installs required packages and creates a local CA if one doesn't already exist.
#
# This is CI infrastructure, not part of the tool itself — it lives on the
# worker at /usr/local/bin/, outside the git repo, and is invoked by the
# Jenkinsfile via a scoped passwordless-sudo rule:
#
#   jenkins ALL=(root) NOPASSWD: /usr/local/bin/jenkins-nginx-cert-prereqs.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root" >&2
    exit 1
fi

echo "Installing prerequisites (openssl, nginx, shellcheck)..."
apt-get update
apt-get install -y openssl nginx shellcheck

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

CA_DIR="/etc/local-ca"
if [[ ! -f "$CA_DIR/rootCA.crt" ]]; then
    echo "No local CA found at $CA_DIR — generating one for this worker..."
    mkdir -p "$CA_DIR/private"
    chmod 700 "$CA_DIR/private"
    openssl genrsa -out "$CA_DIR/private/rootCA.key" 4096
    openssl req -x509 -new -nodes \
        -key "$CA_DIR/private/rootCA.key" \
        -sha256 -days 3650 \
        -out "$CA_DIR/rootCA.crt" \
        -subj "/C=US/ST=Homelab/O=Slade Services/CN=Homelab Local CA"
    echo "Local CA created at $CA_DIR"
else
    echo "Local CA already present at $CA_DIR — skipping generation."
fi

echo "Prerequisites ready."
