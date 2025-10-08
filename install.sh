tee install.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

HTTP_PORT=80
WEBROOT_BASE="/var/www/provisioning"
VHOST_PATH="/etc/nginx/sites-available/provisioning.conf"
VHOST_LINK="/etc/nginx/sites-enabled/provisioning.conf"
DOMAIN=""

die(){ echo "[x] $*" >&2; exit 1; }
log(){ echo "[+] $*"; }
warn(){ echo "[!] $*"; }

self_elevate() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Please run as root (sudo)."
    echo "Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--domain) DOMAIN="$2"; shift 2 ;;
      --http-port) HTTP_PORT="$2"; shift 2 ;;
      --webroot)   WEBROOT_BASE="$2"; shift 2 ;;
      -y|--yes)    export DEBIAN_FRONTEND=noninteractive; shift ;;
      *) warn "Unknown option: $1"; shift ;;
    esac
  done
}

is_valid_fqdn() {
  local d="$1"
  [ -n "$d" ] || return 1
  [[ "$d" =~ ^[^/]+$ ]] || return 1
  [[ ! "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  [[ "$d" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]] || return 1
  return 0
}

prompt_domain() {
  while true; do
    read -rp "Domain (FQDN) für server_name: " DOMAIN || true
    is_valid_fqdn "$DOMAIN" && break || echo "Ungültig. Bitte FQDN ohne http:// und ohne IP."
  done
}

apt_install() {
  log "Installing packages..."
  apt-get update -y
  apt-get install -y --no-install-recommends nginx curl ca-certificates acl
}

check_port() {
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":(?:${HTTP_PORT})$"; then
    warn "Port $HTTP_PORT ist belegt."
    read -rp "(E) Abbrechen oder (A)usweichport verwenden [E/a]: " ans
    if [[ "${ans,,}" == "a" ]]; then
      read -rp "Neuer HTTP-Port (z.B. 8080): " HTTP_PORT
    else
      die "Port $HTTP_PORT belegt – Installation abgebrochen."
    fi
  fi
}

prepare_dirs() {
  log "Preparing webroot at $WEBROOT_BASE"
  mkdir -p "$WEBROOT_BASE/html" "$WEBROOT_BASE/prov" "$WEBROOT_BASE/prov.mac"
  chown -R www-data:www-data "$WEBROOT_BASE" || true

  if [ ! -f "$WEBROOT_BASE/html/index.html" ]; then
    echo "TVIP Provisioning OK" > "$WEBROOT_BASE/html/index.html"
    chown www-data:www-data "$WEBROOT_BASE/html/index.html" || true
  fi

  # Render XML nur, wenn noch nicht vorhanden
  if [ ! -f "$WEBROOT_BASE/prov/tvip_provision.xml" ]; then
    sed -e "s#{{DOMAIN}}#$DOMAIN#g" files/tvip_provision.xml > "$WEBROOT_BASE/prov/tvip_provision.xml"
    chown www-data:www-data "$WEBROOT_BASE/prov/tvip_provision.xml" || true
    chmod 0644 "$WEBROOT_BASE/prov/tvip_provision.xml" || true
  fi
}

install_nginx_vhost() {
  log "Installing NGINX vhost (minimal)"
  sed -e "s#{{WEBROOT_BASE}}#$WEBROOT_BASE#g" \
      -e "s#{{SERVER_NAME}}#$DOMAIN#g" \
      files/nginx-provisioning.conf > "$VHOST_PATH"

  ln -sf "$VHOST_PATH" "$VHOST_LINK"
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || systemctl restart nginx
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW rules"
    ufw allow "${HTTP_PORT}"/tcp || true
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
Domain:    $DOMAIN

HTTP:      http://$DOMAIN:${HTTP_PORT}/
Config:    $VHOST_PATH
Logs:      /var/log/nginx/access.log, /var/log/nginx/error.log
EOF
}

main() {
  self_elevate "$@"
  parse_args "$@"
  is_valid_fqdn "$DOMAIN" || prompt_domain
  echo "Verwenden: $DOMAIN"
  read -rp "[Enter] bestätigen / (n) neu: " ans
  [[ "${ans,,}" == n* ]] && prompt_domain

  apt_install
  check_port
  prepare_dirs
  install_nginx_vhost
  configure_firewall
  summary
}

main "$@"
SH
chmod +x install.sh
