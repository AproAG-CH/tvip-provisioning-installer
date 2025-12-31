#!/usr/bin/env bash
set -Eeuo pipefail

HTTP_PORT=80
WEBROOT_BASE="/var/www/provisioning"
VHOST_PATH="/etc/nginx/sites-available/provisioning.conf"
VHOST_LINK="/etc/nginx/sites-enabled/provisioning.conf"
DOMAIN=""

# Für Raw-Downloads der Templates (falls nicht lokal vorhanden)
RAW_BASE="https://raw.githubusercontent.com/AproAG-CH/tvip-provisioning-installer/main/files"

die(){ echo "[x] $*" >&2; exit 1; }
log(){ echo "[+] $*"; }
warn(){ echo "[!] $*"; }

# stdin/TTY-sichere Eingabe
ask() {
  local prompt="$1"
  local var
  if [ -t 0 ]; then
    # interaktiv
    read -rp "$prompt" var || true
  else
    # piped: lese von /dev/tty
    if [ -r /dev/tty ]; then
      read -rp "$prompt" var < /dev/tty || true
    else
      die "Kein TTY für Eingaben verfügbar. Bitte mit --domain <fqdn> aufrufen."
    fi
  fi
  printf '%s' "${var}"
}

# Root-Elevation robust, auch wenn Script über stdin kommt
self_elevate() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Bitte als root (sudo) ausführen."
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
      exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
      # gepiped
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
      *) warn "Unbekannte Option: $1"; shift ;;
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
    DOMAIN="$(ask 'Domain (FQDN) für server_name: ')"
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
    local ans
    ans="$(ask '(E) Abbrechen oder (A)usweichport verwenden [E/a]: ')"
    if [[ "${ans,,}" == "a" ]]; then
      HTTP_PORT="$(ask 'Neuer HTTP-Port (z.B. 8080): ')"
    else
      die "Port $HTTP_PORT belegt – Installation abgebrochen."
    fi
  fi
}

# Template aus Repo-Datei ODER von GitHub Raw holen
# $1: lokaler relativer Pfad (bezogen auf Scriptdir), $2: Fallback-URL (RAW)
ensure_template() {
  local rel="$1" url="$2" out="$3"
  local basedir=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    basedir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  else
    basedir="$(pwd -P)"
  fi
  local localfile="$basedir/$rel"

  if [ -r "$localfile" ]; then
    cat "$localfile" > "$out"
    return
  fi

  # Fallback: aus RAW laden
  curl -fsSL "$url" -o "$out" \
    || die "Konnte Template nicht laden: $url"
}

prepare_dirs() {
  log "Preparing webroot at $WEBROOT_BASE"
  mkdir -p "$WEBROOT_BASE/html" "$WEBROOT_BASE/prov" "$WEBROOT_BASE/prov.mac"
  chown -R www-data:www-data "$WEBROOT_BASE" || true

  if [ ! -f "$WEBROOT_BASE/html/index.html" ]; then
    echo "TVIP Provisioning OK" > "$WEBROOT_BASE/html/index.html"
    chown www-data:www-data "$WEBROOT_BASE/html/index.html" || true
  fi

  # Default-XML rendern (falls noch nicht vorhanden)
  if [ ! -f "$WEBROOT_BASE/prov/tvip_provision.xml" ]; then
    local tmpxml
    tmpxml="$(mktemp)"
    ensure_template "files/tvip_provision.xml" \
      "${RAW_BASE}/tvip_provision.xml" \
      "$tmpxml"
    sed -e "s#{{DOMAIN}}#$DOMAIN#g" "$tmpxml" > "$WEBROOT_BASE/prov/tvip_provision.xml"
    rm -f "$tmpxml"
    chown www-data:www-data "$WEBROOT_BASE/prov/tvip_provision.xml" || true
    chmod 0644 "$WEBROOT_BASE/prov/tvip_provision.xml" || true
  fi
}

install_nginx_vhost() {
  log "Installing NGINX vhost (minimal)"
  local tmpvhost
  tmpvhost="$(mktemp)"
  ensure_template "files/nginx-provisioning.conf" \
    "${RAW_BASE}/nginx-provisioning.conf" \
    "$tmpvhost"

  sed -e "s#{{WEBROOT_BASE}}#$WEBROOT_BASE#g" \
      -e "s#{{SERVER_NAME}}#$DOMAIN#g" \
      "$tmpvhost" > "$VHOST_PATH"
  rm -f "$tmpvhost"

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

  if ! is_valid_fqdn "$DOMAIN"; then
    prompt_domain
  fi
  echo "Verwenden: $DOMAIN"
  local ans
  ans="$(ask '[Enter] bestätigen / (n) neu: ')"
  [[ "${ans,,}" == n* ]] && prompt_domain

  apt_install
  check_port
  prepare_dirs
  install_nginx_vhost
  configure_firewall
  summary
}

main "$@"
