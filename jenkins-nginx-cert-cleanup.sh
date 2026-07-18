#!/bin/bash
# jenkins-nginx-cert-cleanup.sh <domain>
#
# Removes the cert and Nginx site created for <domain> by issue-local-cert.sh,
# used to clean up after the optional Jenkins "Issuance Test" stage.
#
# This is CI infrastructure, not part of the tool itself — it lives on the
# worker at /usr/local/bin/, outside the git repo, and is invoked by the
# Jenkinsfile via a scoped passwordless-sudo rule:
#
#   jenkins ALL=(root) NOPASSWD: /usr/local/bin/jenkins-nginx-cert-cleanup.sh *
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root" >&2
    exit 1
fi

DOMAIN="${1:?Usage: $0 <domain>}"

rm -rf "/etc/local-ca/issued/$DOMAIN"
rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t && systemctl reload nginx

echo "Cleaned up $DOMAIN"
