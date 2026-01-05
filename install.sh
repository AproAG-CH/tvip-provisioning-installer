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

# --- Minimal-Templates (ohne Kommentare im Ziel-File) -------------------------
template_xml() {
cat <<'XML'
<?xml version="1.0"?>
<provision reload="3000">
  <provision_server name="http://{{DOMAIN}}" />
  <time tz="Europe/Zurich" ntp="pool.ntp.org" time_format="24" />
  <features>
    <tv enabled="true" />
    <mediaplayer enabled="true" />
    <dvr enabled="true" />
    <cctv enabled="true" />
  </features>
  <preferences>
    <pref_system visible="false" />
    <pref_appearance visible="false" />
    <pref_network visible="false" />
    <pref_display visible="false" />
    <pref_tv visible="false" />
    <pref_security visible="false" />
  </preferences>
</provision>
XML
}

template_nginx() {
cat <<'NGINX'
server {
    listen {{HTTP_PORT}};
    listen [::]:{{HTTP_PORT}};
    server_name {{SERVER_NAME}} www.{{SERVER_NAME}};
    root {{WEBROOT_BASE}};
    index html/index.html index.html;

    location = / {
        try_files /html/index.html =404;
    }

    location /html/ { try_files $uri =404; }
    location /prov/ { try_files $uri =404; }
    location /prov.mac/ { try_files $uri =404; }

    location ~ ^/prov/(?<rest>.*)$ {
        try_files /prov.mac/$http_mac_address/$rest /prov/$rest =404;
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;
}
NGINX
}
# ------------------------------------------------------------------------------

self_elevate() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Please run as root (sudo)."
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
      exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
      exec sudo -E bash -s -- "$@" < /dev/stdin
    fi
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--domain) DOMAIN="${2:?}"; shift 2 ;;
      --http-port) HTTP_PORT="${2:?}"; shift 2 ;;
      --webroot)   WEBROOT_BASE="${2:?}"; shift 2 ;;
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

# liest immer vom echten TTY, auch wenn das Skript über eine Pipe läuft
read_tty() {
  local prompt="$1" outvar="$2" reply
  if exec 3<>/dev/tty 2>/dev/null; then
    printf "%s" "$prompt" >&3
    IFS= read -r reply <&3 || { exec 3>&- 3<&-; die "Keine Eingabe möglich."; }
    printf -v "$outvar" "%s" "$reply"
    exec 3>&- 3<&-
  else
    die "Kein TTY verfügbar. Alternativ per Flag übergeben (z. B. --domain <fqdn>)."
  fi
}

prompt_domain() {
  while true; do
    read_tty "Domain (FQDN) für server_name: " DOMAIN
    is_valid_fqdn "$DOMAIN" && break || echo "Ungültig. Bitte FQDN ohne http:// und ohne IP."
  done
}

apt_install() {
  log "Installing packages..."
  apt-get update -y
  apt-get install -y --no-install-recommends nginx curl ca-certificates acl iproute2
}

check_port() {
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":(?:${HTTP_PORT})$"; then
    warn "Port $HTTP_PORT ist belegt."
    local ans=""
    read_tty "(E) Abbrechen oder (A)usweichport verwenden [E/a]: " ans
    if [[ "${ans,,}" == "a" ]]; then
      read_tty "Neuer HTTP-Port (z.B. 8080): " HTTP_PORT
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

  if [ ! -f "$WEBROOT_BASE/prov/tvip_provision.xml" ]; then
    template_xml | sed -e "s#{{DOMAIN}}#$DOMAIN#g" > "$WEBROOT_BASE/prov/tvip_provision.xml"
    [ -s "$WEBROOT_BASE/prov/tvip_provision.xml" ] || die "Rendering tvip_provision.xml fehlgeschlagen."
    chown www-data:www-data "$WEBROOT_BASE/prov/tvip_provision.xml" || true
    chmod 0644 "$WEBROOT_BASE/prov/tvip_provision.xml" || true
  fi
}

install_nginx_vhost() {
  log "Installing NGINX vhost"
  template_nginx \
    | sed -e "s#{{WEBROOT_BASE}}#$WEBROOT_BASE#g" \
          -e "s#{{SERVER_NAME}}#$DOMAIN#g" \
          -e "s#{{HTTP_PORT}}#$HTTP_PORT#g" \
    > "$VHOST_PATH"

  [ -s "$VHOST_PATH" ] || die "Rendering provisioning.conf fehlgeschlagen."
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
  local ans=""
  read_tty "[Enter] bestätigen / (n) neu: " ans || true
  [[ "${ans,,}" == n* ]] && prompt_domain

  apt_install
  check_port
  prepare_dirs
  install_nginx_vhost
  configure_firewall
  summary
}

main "$@"
