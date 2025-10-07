#!/usr/bin/env bash
set -Eeuo pipefail

# TVIP Provisioning Server installer for Ubuntu 22.04 LTS (HTTP only)
# - Self-elevates to sudo if not run as root
# - Requires a valid domain (FQDN) for server_name (no IP, no empty value)
# - Sets up NGINX static hosting for TVIP provisioning
# - Creates canonical folder structure: /var/www/provisioning/{prov,prov.mac}
# - Installs sample tvip_provision.xml (only if missing)
# - Adds MAC-based rewrite logic
# - Idempotent: safe to re-run

HTTP_PORT=80
WEBROOT_BASE="/var/www/provisioning"
VHOST_PATH="/etc/nginx/sites-available/provisioning.conf"
VHOST_LINK="/etc/nginx/sites-enabled/provisioning.conf"
DOMAIN=""   # REQUIRED (FQDN)
HEADER_NAME="MAC-Address" # change if your STB uses a different header

log() { echo -e "[1;32m[+][0m $*"; }
warn() { echo -e "[1;33m[!][0m $*"; }
err() { echo -e "[1;31m[x][0m $*" >&2; }

die() { err "$1"; exit 1; }

self_elevate() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "This installer needs root. Re-running with sudo..."
      exec sudo -E bash "$0" "$@"
    else
      die "Please run as root (e.g., sudo bash install.sh)."
    fi
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--domain) DOMAIN="$2"; shift 2 ;;
      --http-port) HTTP_PORT="$2"; shift 2 ;;
      --header-name) HEADER_NAME="$2"; shift 2 ;;
      -y|--yes) export DEBIAN_FRONTEND=noninteractive; shift ;;
      *) warn "Unknown option: $1"; shift ;;
    esac
  done
}

is_valid_fqdn() {
  local d="$1"
  [[ -n "$d" ]] || return 1
  [[ "$d" =~ ^[^/]+$ ]] || return 1
  if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 1; fi
  [[ "$d" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]] || return 1
  return 0
}

prompt_domain() {
  while true; do
    read -rp "Domain (FQDN) für server_name (Pflicht, z.B. provisioning.example.com): " DOMAIN || true
    if is_valid_fqdn "$DOMAIN"; then
      break
    else
      echo "Ungültige Domain. Bitte eine FQDN ohne http:// und ohne IP eingeben."
    fi
  done
}

apt_install() {
  log "Installing packages..."
  apt-get update -y
  apt-get install -y --no-install-recommends nginx curl ca-certificates acl
}

prepare_dirs() {
  log "Preparing webroot at $WEBROOT_BASE"
  mkdir -p "$WEBROOT_BASE/prev" "$WEBROOT_BASE/prov" "$WEBROOT_BASE/prov.mac"
  chown -R www-data:www-data "$WEBROOT_BASE"
  setfacl -Rm u:www-data:rx "$WEBROOT_BASE" || true
  if [[ ! -f "$WEBROOT_BASE/prov/tvip_provision.xml" ]]; then
    install -m 0644 files/tvip_provision.xml "$WEBROOT_BASE/prov/tvip_provision.xml"
    chown www-data:www-data "$WEBROOT_BASE/prov/tvip_provision.xml"
  fi
}

install_nginx_vhost() {
  log "Installing NGINX vhost (minimal)"
  local server_name="$DOMAIN"

  sed -e "s#{{WEBROOT_BASE}}#$WEBROOT_BASE#g" \
      -e "s#{{SERVER_NAME}}#$server_name#g" \
      files/nginx-provisioning.conf > "$VHOST_PATH"

  ln -sf "$VHOST_PATH" "$VHOST_LINK"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || systemctl restart nginx
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW rules"
    ufw allow "$HTTP_PORT"/tcp || true
  fi
}

summary() {
  cat <<EOF

============================================================
 TVIP Provisioning Server – Installation Complete (HTTP)
============================================================
Webroot:   $WEBROOT_BASE
Default:   $WEBROOT_BASE/prov/tvip_provision.xml
Per-MAC:   $WEBROOT_BASE/prov.mac/<MAC>/tvip_provision.xml
Header:    $HEADER_NAME

HTTP:      http://$DOMAIN:$HTTP_PORT/
Config:    $VHOST_PATH
Logs:      /var/log/nginx/provisioning.access.log, /var/log/nginx/provisioning.error.log

Re-run this installer anytime; it is idempotent.
EOF
}

main() {
  self_elevate "$@"
  parse_args "$@"
  if ! is_valid_fqdn "$DOMAIN"; then
    prompt_domain
  fi
  apt_install
  prepare_dirs
  install_nginx_vhost
  configure_firewall
  summary
}

main "$@"
