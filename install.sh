#!/usr/bin/env bash
set -Eeuo pipefail

HTTP_PORT=80
SERVICE_NAME="tvip_provisioning_server"
INSTANCE="server1"
WEBROOT_ROOT=""
WEBROOT_BASE=""
VHOST_PATH=""
VHOST_LINK=""
LEGACY_WEBROOT_BASE="/var/www/provisioning"
CURRENT_FLAT_WEBROOT_BASE="/var/www/tvip_provisioning_server"
LEGACY_VHOST_PATH="/etc/nginx/sites-available/provisioning.conf"
LEGACY_VHOST_LINK="/etc/nginx/sites-enabled/provisioning.conf"
DEFAULT_VHOST_NAME="tvip_provisioning_server"
DOMAIN=""
FORCE_XML=0
YES=0
REMOVE_DEFAULT=0
DRY_RUN=0
LIST_INSTANCES=0
SHOW_HELP=0
IS_UPGRADE=0
IS_LEGACY_UPGRADE=0
INSTANCE_SET=0
WEBROOT_SET=0
MIGRATE_WEBROOT_FROM=""
MIGRATE_FLAT_WEBROOT=0
MIGRATION_SOURCE_VHOST=""
MIGRATION_SOURCE_LINK=""
BACKUP_DIR="/var/backups/tvip_provisioning_server"
BACKUP_PATH=""
OLD_VHOST_BACKUP=""

die(){ echo "[x] $*" >&2; exit 1; }
log(){ echo "[+] $*"; }
warn(){ echo "[!] $*"; }
lower(){ printf "%s" "$1" | tr '[:upper:]' '[:lower:]'; }
reset_migration_state() {
  MIGRATE_WEBROOT_FROM=""
  MIGRATE_FLAT_WEBROOT=0
  MIGRATION_SOURCE_VHOST=""
  MIGRATION_SOURCE_LINK=""
  IS_LEGACY_UPGRADE=0
}

usage() {
cat <<'EOF'
TVIP Provisioning Server Installer

Usage:
  sudo bash install.sh [options]

Options:
  -d, --domain <fqdn>          Domain for NGINX server_name and default XML
      --instance <name>        Server folder under /var/www/tvip_provisioning_server
      --http-port <port>       HTTP port, default 80
      --webroot <path>         Explicit provisioning root for advanced installs
      --force-xml              Replace prov/tvip_provision.xml
      --remove-default-site    Remove /etc/nginx/sites-enabled/default
      --dry-run                Show planned actions without changing the system
      --list-instances         List existing provisioning server instances
  -y, --yes                    Non-interactive mode where possible
  -h, --help                   Show this help
EOF
}

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
    <pref_system visible="true" />
    <pref_appearance visible="true" />
    <pref_network visible="true" />
    <pref_display visible="true" />
    <pref_tv visible="true" />
    <pref_security visible="true" />
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

    root {{WEBROOT_BASE}}/html;
    index index.html index.htm;

    if ($http_mac_address) { set $tvipmac M; }
    if (-d "{{WEBROOT_BASE}}/prov.mac/$http_mac_address/") { set $tvipres F$tvipmac; }
    if ($tvipres = FM) { rewrite ^/prov/(.*)$ /prov.mac/$http_mac_address/$1 last; }

    location /prov.mac/ { alias {{WEBROOT_BASE}}/prov.mac/; }
    location /prov/     { alias {{WEBROOT_BASE}}/prov/; }
}
NGINX
}

script_dir() {
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
    dirname "${BASH_SOURCE[0]}"
  else
    pwd
  fi
}

source_template_xml() {
  local file
  file="$(script_dir)/files/tvip_provision.xml"
  if [ -r "$file" ]; then
    cat "$file"
  else
    template_xml
  fi
}

source_template_nginx() {
  local file
  file="$(script_dir)/files/tvip_provisioning_server.conf"
  if [ -r "$file" ]; then
    cat "$file"
  else
    template_nginx
  fi
}

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
      --instance) INSTANCE="${2:?}"; INSTANCE_SET=1; shift 2 ;;
      -d|--domain) DOMAIN="${2:?}"; shift 2 ;;
      --http-port) HTTP_PORT="${2:?}"; shift 2 ;;
      --webroot)   WEBROOT_BASE="${2:?}"; WEBROOT_SET=1; shift 2 ;;
      --force-xml) FORCE_XML=1; shift ;;
      --remove-default-site) REMOVE_DEFAULT=1; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --list-instances) LIST_INSTANCES=1; shift ;;
      -y|--yes)    YES=1; export DEBIAN_FRONTEND=noninteractive; shift ;;
      -h|--help)   SHOW_HELP=1; shift ;;
      *) warn "Unknown option: $1"; shift ;;
    esac
  done
}

is_valid_instance() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
}

is_valid_fqdn() {
  local d="$1"
  [ -n "$d" ] || return 1
  [[ "$d" =~ ^[^/]+$ ]] || return 1
  [[ ! "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  [[ "$d" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]] || return 1
  return 0
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

instance_vhost_name() {
  local inst="$1"
  if [ "$inst" = "server1" ]; then
    printf "%s" "$DEFAULT_VHOST_NAME"
  else
    printf "%s_%s" "$SERVICE_NAME" "$inst"
  fi
}

set_instance_paths() {
  local inst="$1"
  INSTANCE="$inst"
  is_valid_instance "$INSTANCE" || die "Ungültiger Instanzname: $INSTANCE"

  local vhost_name
  vhost_name="$(instance_vhost_name "$INSTANCE")"
  VHOST_PATH="/etc/nginx/sites-available/${vhost_name}.conf"
  VHOST_LINK="/etc/nginx/sites-enabled/${vhost_name}.conf"
  WEBROOT_ROOT="/var/www/${SERVICE_NAME}"

  if [ "$WEBROOT_SET" -eq 0 ]; then
    WEBROOT_BASE="$WEBROOT_ROOT/${INSTANCE}"
  fi
}

discover_instances() {
  local inst path
  DISCOVERED_INSTANCES=()
  [ -d "$WEBROOT_ROOT" ] || return 0

  for path in "$WEBROOT_ROOT"/*; do
    [ -d "$path" ] || continue
    inst="$(basename "$path")"
    is_valid_instance "$inst" || continue
    [ -d "$path/prov" ] || [ -d "$path/prov.mac" ] || [ -f "$path/html/index.html" ] || continue
    DISCOVERED_INSTANCES+=("$inst")
  done
}

resolve_paths() {
  set_instance_paths "$INSTANCE"
  WEBROOT_ROOT="/var/www/${SERVICE_NAME}"

  if [ "$WEBROOT_SET" -eq 0 ]; then
    if [ "$INSTANCE" = "server1" ] \
      && [ ! -d "$WEBROOT_ROOT" ] \
      && [ ! -d "$WEBROOT_ROOT/server1" ] \
      && { [ -d "$LEGACY_WEBROOT_BASE" ] || [ -f "$LEGACY_VHOST_PATH" ]; }; then
      WEBROOT_BASE="$WEBROOT_ROOT/server1"
      [ -f "$VHOST_PATH" ] || IS_LEGACY_UPGRADE=1
      [ ! -d "$LEGACY_WEBROOT_BASE" ] || MIGRATE_WEBROOT_FROM="$LEGACY_WEBROOT_BASE"
      [ ! -f "$LEGACY_VHOST_PATH" ] || MIGRATION_SOURCE_VHOST="$LEGACY_VHOST_PATH"
      [ ! -L "$LEGACY_VHOST_LINK" ] || MIGRATION_SOURCE_LINK="$LEGACY_VHOST_LINK"
    elif [ "$INSTANCE" = "server1" ] \
      && [ -d "$CURRENT_FLAT_WEBROOT_BASE" ] \
      && [ -d "$CURRENT_FLAT_WEBROOT_BASE/prov" ] \
      && [ ! -d "$WEBROOT_ROOT/server1" ]; then
      WEBROOT_BASE="$WEBROOT_ROOT/server1"
      MIGRATE_WEBROOT_FROM="$CURRENT_FLAT_WEBROOT_BASE"
      MIGRATE_FLAT_WEBROOT=1
      [ ! -f "$VHOST_PATH" ] || MIGRATION_SOURCE_VHOST="$VHOST_PATH"
      [ ! -L "$VHOST_LINK" ] || MIGRATION_SOURCE_LINK="$VHOST_LINK"
    fi
  fi
}

select_existing_instance() {
  [ "$INSTANCE_SET" -eq 0 ] || return 0
  [ "$WEBROOT_SET" -eq 0 ] || return 0

  discover_instances
  [ "${#DISCOVERED_INSTANCES[@]}" -gt 0 ] || return 0

  reset_migration_state

  if [ "$YES" -eq 1 ]; then
    if [ "${#DISCOVERED_INSTANCES[@]}" -eq 1 ]; then
      set_instance_paths "${DISCOVERED_INSTANCES[0]}"
      return 0
    fi
    die "Mehrere Provisioning Server gefunden. Bitte mit --instance <name> auswählen."
  fi

  echo "Bestehende Provisioning Server gefunden."
  local add=""
  read_tty "Weiteren Provisioning Server hinzufügen? [j/N] " add
  case "$(lower "$add")" in
    j|ja|y|yes)
      prompt_new_instance_domain
      IS_UPGRADE=0
      reset_migration_state
      set_instance_paths "$INSTANCE"
      return 0
      ;;
  esac

  if [ "${#DISCOVERED_INSTANCES[@]}" -eq 1 ]; then
    set_instance_paths "${DISCOVERED_INSTANCES[0]}"
    return 0
  fi

  echo "Welche Installation soll aktualisiert werden?"
  local i
  for i in "${!DISCOVERED_INSTANCES[@]}"; do
    echo "  $((i + 1))) ${DISCOVERED_INSTANCES[$i]}"
  done

  local ans idx
  while true; do
    read_tty "Welche Installation aktualisieren? [1-${#DISCOVERED_INSTANCES[@]}]: " ans
    [[ "$ans" =~ ^[0-9]+$ ]] || { echo "Bitte Nummer auswählen."; continue; }
    idx=$((ans - 1))
    [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DISCOVERED_INSTANCES[@]}" ] || { echo "Ungültige Auswahl."; continue; }
    set_instance_paths "${DISCOVERED_INSTANCES[$idx]}"
    break
  done
}

detect_existing_install() {
  if [ -n "$MIGRATE_WEBROOT_FROM" ]; then
    IS_UPGRADE=1
    return 0
  fi

  if [ -d "$WEBROOT_BASE" ] || [ -f "$VHOST_PATH" ]; then
    IS_UPGRADE=1
    if [ "$INSTANCE" = "server1" ] \
      && [ ! -f "$VHOST_PATH" ] \
      && { [ "$WEBROOT_BASE" = "$LEGACY_WEBROOT_BASE" ] || [ -f "$LEGACY_VHOST_PATH" ]; }; then
      IS_LEGACY_UPGRADE=1
    fi
    return 0
  fi

  if [ "$INSTANCE" = "server1" ] \
    && { [ -d "$LEGACY_WEBROOT_BASE" ] || [ -f "$LEGACY_VHOST_PATH" ]; }; then
    IS_UPGRADE=1
    IS_LEGACY_UPGRADE=1
  fi
}

detect_existing_domain() {
  local xml="$WEBROOT_BASE/prov/tvip_provision.xml"
  local detect_vhost

  if [ -n "$MIGRATE_WEBROOT_FROM" ]; then
    xml="$MIGRATE_WEBROOT_FROM/prov/tvip_provision.xml"
  fi
  detect_vhost="$(detect_vhost_path)"

  if [ -z "$DOMAIN" ] && [ -f "$detect_vhost" ]; then
    DOMAIN="$(domain_from_vhost "$detect_vhost" || true)"
  fi

  if [ -z "$DOMAIN" ] && [ -f "$xml" ]; then
    DOMAIN="$(domain_from_xml "$xml" || true)"
  fi
}

detect_vhost_path() {
  if [ -n "$MIGRATION_SOURCE_VHOST" ]; then
    printf "%s" "$MIGRATION_SOURCE_VHOST"
  elif [ "$IS_LEGACY_UPGRADE" -eq 1 ] && [ ! -f "$VHOST_PATH" ]; then
    printf "%s" "$LEGACY_VHOST_PATH"
  else
    printf "%s" "$VHOST_PATH"
  fi
}

domain_from_xml() {
  local xml="$1" found=""
  [ -f "$xml" ] || return 1
  found="$(sed -nE 's#.*<provision_server[[:space:]][^>]*name="https?://([^/:"]+).*#\1#p' "$xml" | head -n1 || true)"
  is_valid_fqdn "$found" || return 1
  printf "%s" "$found"
}

domain_from_vhost() {
  local conf="$1" found=""
  [ -f "$conf" ] || return 1
  found="$(sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^ ;]+).*/\1/p' "$conf" | head -n1 || true)"
  is_valid_fqdn "$found" || return 1
  printf "%s" "$found"
}

print_instances() {
  WEBROOT_ROOT="/var/www/${SERVICE_NAME}"
  discover_instances

  if [ "${#DISCOVERED_INSTANCES[@]}" -eq 0 ]; then
    echo "No current instances found under $WEBROOT_ROOT"
  else
    local inst old_instance webroot vhost domain
    old_instance="$INSTANCE"
    for inst in "${DISCOVERED_INSTANCES[@]}"; do
      set_instance_paths "$inst"
      webroot="$WEBROOT_BASE"
      vhost="$VHOST_PATH"
      domain="$(domain_from_vhost "$vhost" || true)"
      [ -n "$domain" ] || domain="$(domain_from_xml "$webroot/prov/tvip_provision.xml" || true)"
      [ -n "$domain" ] || domain="-"
      printf "%s -> %s -> %s\n" "$inst" "$domain" "$webroot"
    done
    set_instance_paths "$old_instance"
  fi

  if [ -d "$LEGACY_WEBROOT_BASE" ] || [ -f "$LEGACY_VHOST_PATH" ]; then
    local legacy_domain="-"
    legacy_domain="$(domain_from_vhost "$LEGACY_VHOST_PATH" || true)"
    [ -n "$legacy_domain" ] || legacy_domain="$(domain_from_xml "$LEGACY_WEBROOT_BASE/prov/tvip_provision.xml" || true)"
    [ -n "$legacy_domain" ] || legacy_domain="-"
    printf "legacy provisioning -> %s -> %s\n" "$legacy_domain" "$LEGACY_WEBROOT_BASE"
  fi
}

detect_existing_port() {
  local found=""
  local detect_vhost
  detect_vhost="$(detect_vhost_path)"

  if [ "$HTTP_PORT" = "80" ] && [ -f "$detect_vhost" ]; then
    found="$(sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)([[:space:];].*)?$/\1/p' "$detect_vhost" | head -n1 || true)"
    if is_valid_port "$found"; then
      HTTP_PORT="$found"
    fi
  fi
}

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

prompt_instance() {
  while true; do
    read_tty "Name für weiteren Server (z.B. server2 oder hotel-b.example.com): " INSTANCE
    is_valid_instance "$INSTANCE" && break || echo "Ungültig. Erlaubt: Buchstaben, Zahlen, Punkt, _ und -."
  done
  INSTANCE_SET=1
}

prompt_new_instance_domain() {
  DOMAIN=""
  prompt_domain

  local ans=""
  read_tty "Domain als Ordnername verwenden? [J/n] " ans
  case "$(lower "$ans")" in
    n|nein|no)
      prompt_instance
      ;;
    *)
      INSTANCE="$DOMAIN"
      INSTANCE_SET=1
      ;;
  esac
}

choose_migration_name() {
  [ -n "$MIGRATE_WEBROOT_FROM" ] || return 0
  [ "$WEBROOT_SET" -eq 0 ] || return 0
  [ "$INSTANCE_SET" -eq 0 ] || return 0

  local selected="provisioning"
  if is_valid_fqdn "$DOMAIN"; then
    selected="$DOMAIN"
  fi

  if [ "$YES" -eq 0 ] && is_valid_fqdn "$DOMAIN"; then
    echo "Upgrade-Zielordner unter /var/www/${SERVICE_NAME}:"
    echo "  1) provisioning"
    echo "  2) $DOMAIN"
    local ans=""
    read_tty "Ordnername wählen [2/1]: " ans
    case "$(lower "$ans")" in
      1|p|provisioning) selected="provisioning" ;;
      *) selected="$DOMAIN" ;;
    esac
  elif [ "$YES" -eq 0 ]; then
    echo "Keine gültige Domain im Bestand gefunden; verwende Ordnername provisioning."
  fi

  INSTANCE="$selected"
  is_valid_instance "$INSTANCE" || die "Ungültiger Zielordner: $INSTANCE"
  set_instance_paths "$INSTANCE"
}

confirm_domain() {
  [ "$YES" -eq 0 ] || return 0
  echo "Verwenden: $DOMAIN"
  local ans=""
  read_tty "[Enter] bestätigen / (n) neu: " ans || true
  if [[ "$(lower "$ans")" == n* ]]; then
    prompt_domain
  fi
  return 0
}

apt_install() {
  local required_packages=(nginx)
  local optional_packages=(iproute2)
  local missing_required=()
  local missing_optional=()
  local pkg

  if command -v dpkg-query >/dev/null 2>&1; then
    for pkg in "${required_packages[@]}"; do
      if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        missing_required+=("$pkg")
      fi
    done
    for pkg in "${optional_packages[@]}"; do
      if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        missing_optional+=("$pkg")
      fi
    done
  else
    missing_required=("${required_packages[@]}")
    missing_optional=("${optional_packages[@]}")
  fi

  if [ "${#missing_required[@]}" -eq 0 ] && [ "${#missing_optional[@]}" -eq 0 ]; then
    log "Required packages already installed"
    return 0
  fi

  if ! apt-get update -y; then
    if [ "${#missing_required[@]}" -eq 0 ]; then
      warn "apt-get update fehlgeschlagen; optionale Pakete werden übersprungen."
      return 0
    fi
    die "apt-get update fehlgeschlagen."
  fi

  if [ "${#missing_required[@]}" -gt 0 ]; then
    log "Installing required packages: ${missing_required[*]}"
    apt-get install -y --no-install-recommends "${missing_required[@]}" || die "Paketinstallation fehlgeschlagen: ${missing_required[*]}"
  fi

  if [ "${#missing_optional[@]}" -gt 0 ]; then
    log "Installing optional packages: ${missing_optional[*]}"
    apt-get install -y --no-install-recommends "${missing_optional[@]}" || warn "Optionale Paketinstallation fehlgeschlagen: ${missing_optional[*]}"
  fi
}

create_migration_backup() {
  [ -n "$MIGRATE_WEBROOT_FROM" ] || return 0
  command -v tar >/dev/null 2>&1 || { warn "tar nicht gefunden; überspringe Backup."; return 0; }

  mkdir -p "$BACKUP_DIR"
  BACKUP_PATH="$BACKUP_DIR/$(basename "$MIGRATE_WEBROOT_FROM")-$(date +%Y%m%d%H%M%S).tar.gz"
  log "Creating backup at $BACKUP_PATH"
  tar -czf "$BACKUP_PATH" -C "$(dirname "$MIGRATE_WEBROOT_FROM")" "$(basename "$MIGRATE_WEBROOT_FROM")"
}

check_port() {
  is_valid_port "$HTTP_PORT" || die "Ungültiger HTTP-Port: $HTTP_PORT"
  if [ "$IS_UPGRADE" -eq 1 ]; then
    log "Upgrade mode detected; keeping HTTP port $HTTP_PORT"
    return 0
  fi

  local listener=""
  listener="$(ss -lntp 2>/dev/null | awk -v port=":${HTTP_PORT}" '$4 ~ port "$" {print $0; exit}' || true)"
  [ -n "$listener" ] || return 0

  if echo "$listener" | grep -q 'nginx'; then
    log "Port $HTTP_PORT is already served by NGINX; adding another server block"
    if command -v nginx >/dev/null 2>&1; then
      nginx -t
    fi
    return 0
  fi

  if [ -n "$listener" ]; then
    warn "Port $HTTP_PORT ist durch einen anderen Prozess belegt."
    local ans=""
    [ "$YES" -eq 0 ] || die "Port $HTTP_PORT belegt – Installation abgebrochen."
    read_tty "(E) Abbrechen oder (A)usweichport verwenden [E/a]: " ans
    if [[ "$(lower "$ans")" == "a" ]]; then
      read_tty "Neuer HTTP-Port (z.B. 8080): " HTTP_PORT
      is_valid_port "$HTTP_PORT" || die "Ungültiger HTTP-Port: $HTTP_PORT"
    else
      die "Port $HTTP_PORT belegt – Installation abgebrochen."
    fi
  fi
}

check_domain_conflict() {
  is_valid_fqdn "$DOMAIN" || return 0

  local conf name
  for conf in /etc/nginx/sites-available/*.conf /etc/nginx/sites-enabled/*.conf; do
    [ -e "$conf" ] || continue
    [ "$conf" = "$VHOST_PATH" ] && continue
    [ "$conf" = "$VHOST_LINK" ] && continue
    [ -n "$MIGRATION_SOURCE_VHOST" ] && [ "$conf" = "$MIGRATION_SOURCE_VHOST" ] && continue
    [ -n "$MIGRATION_SOURCE_LINK" ] && [ "$conf" = "$MIGRATION_SOURCE_LINK" ] && continue

    while IFS= read -r name; do
      [ "$name" != "$DOMAIN" ] && [ "$name" != "www.$DOMAIN" ] && continue
      die "Domain $DOMAIN ist bereits in $conf konfiguriert."
    done < <(sed -nE 's/^[[:space:]]*server_name[[:space:]]+(.+);[[:space:]]*$/\1/p' "$conf" | tr ' ' '\n')
  done
}

render_default_xml() {
  source_template_xml | sed -e "s#{{DOMAIN}}#$(sed_escape_replacement "$DOMAIN")#g"
}

sed_escape_replacement() {
  printf "%s" "$1" | sed -e 's/[\/&]/\\&/g' -e 's/#/\\#/g'
}

is_valid_xml_file() {
  local xml="$1"
  [ -s "$xml" ] || return 1

  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$xml" >/dev/null 2>&1
    return $?
  fi

  head -n1 "$xml" 2>/dev/null | grep -q '^<\?xml'
}

migrate_webroot() {
  [ -n "$MIGRATE_WEBROOT_FROM" ] || return 0
  [ "$WEBROOT_SET" -eq 0 ] || return 0
  [ ! -e "$WEBROOT_BASE" ] || die "Ziel-Webroot existiert bereits: $WEBROOT_BASE"

  log "Migrating webroot from $MIGRATE_WEBROOT_FROM to $WEBROOT_BASE"
  mkdir -p "$WEBROOT_ROOT"

  if [ "$MIGRATE_FLAT_WEBROOT" -eq 1 ]; then
    mkdir -p "$WEBROOT_BASE"
    local item
    for item in "$MIGRATE_WEBROOT_FROM"/* "$MIGRATE_WEBROOT_FROM"/.[!.]* "$MIGRATE_WEBROOT_FROM"/..?*; do
      [ -e "$item" ] || continue
      [ "$(basename "$item")" = "$(basename "$WEBROOT_BASE")" ] && continue
      mv "$item" "$WEBROOT_BASE/"
    done
  else
    mv "$MIGRATE_WEBROOT_FROM" "$WEBROOT_BASE"
  fi

  chown -R www-data:www-data "$WEBROOT_ROOT" || true
}

dry_run_summary() {
  cat <<EOF

============================================================
TVIP Provisioning Server – Dry Run
============================================================
Mode:              $([ "$IS_UPGRADE" -eq 1 ] && echo "Upgrade/Refresh" || echo "Fresh install")
Instance:          $INSTANCE
Domain:            $DOMAIN
HTTP port:         $HTTP_PORT
Webroot root:      $WEBROOT_ROOT
Target webroot:    $WEBROOT_BASE
NGINX available:   $VHOST_PATH
NGINX enabled:     $VHOST_LINK
Default XML:       $WEBROOT_BASE/prov/tvip_provision.xml
Per-MAC folder:    $WEBROOT_BASE/prov.mac/<MAC>/
Migration source:  ${MIGRATE_WEBROOT_FROM:-none}
Old vhost source:  ${MIGRATION_SOURCE_VHOST:-none}
Old enabled link:  ${MIGRATION_SOURCE_LINK:-none}
Backup path:       $([ -n "$MIGRATE_WEBROOT_FROM" ] && echo "$BACKUP_DIR/$(basename "$MIGRATE_WEBROOT_FROM")-<timestamp>.tar.gz" || echo "none")

No changes were made.
EOF
}

prepare_dirs() {
  log "Preparing webroot at $WEBROOT_BASE"
  mkdir -p "$WEBROOT_BASE/html" "$WEBROOT_BASE/prov" "$WEBROOT_BASE/prov.mac"
  chown -R www-data:www-data "$WEBROOT_BASE" || true

  if [ ! -f "$WEBROOT_BASE/html/index.html" ]; then
    printf "OK\n" > "$WEBROOT_BASE/html/index.html"
    chown www-data:www-data "$WEBROOT_BASE/html/index.html" || true
  fi

  local xml="$WEBROOT_BASE/prov/tvip_provision.xml"
  if [ "$FORCE_XML" -eq 1 ] || ! is_valid_xml_file "$xml"; then
    [ ! -s "$xml" ] || cp -a "$xml" "${xml}.bak.$(date +%Y%m%d%H%M%S)"
    local tmp="${xml}.tmp.$$"
    render_default_xml > "$tmp" || die "Rendering tvip_provision.xml fehlgeschlagen."
    mv -f "$tmp" "$xml"
    chown www-data:www-data "$xml" || true
    chmod 0644 "$xml" || true
  else
    log "Keeping existing $xml"
  fi
}

install_nginx_vhost() {
  log "Installing NGINX vhost"
  local tmp="${VHOST_PATH}.tmp.$$"
  local escaped_webroot escaped_domain
  escaped_webroot="$(sed_escape_replacement "$WEBROOT_BASE")"
  escaped_domain="$(sed_escape_replacement "$DOMAIN")"

  source_template_nginx \
    | sed -e "s#{{WEBROOT_BASE}}#$escaped_webroot#g" \
          -e "s#{{SERVER_NAME}}#$escaped_domain#g" \
          -e "s#{{HTTP_PORT}}#$HTTP_PORT#g" \
    > "$tmp"

  [ -s "$tmp" ] || die "Rendering NGINX vhost fehlgeschlagen."

  if [ -f "$VHOST_PATH" ] && cmp -s "$tmp" "$VHOST_PATH"; then
    rm -f "$tmp"
    log "Keeping existing NGINX vhost; already up to date"
  else
    if [ -f "$VHOST_PATH" ]; then
      OLD_VHOST_BACKUP="${VHOST_PATH}.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$VHOST_PATH" "$OLD_VHOST_BACKUP"
    fi
    mv -f "$tmp" "$VHOST_PATH"
  fi

  [ -s "$VHOST_PATH" ] || die "Rendering NGINX vhost fehlgeschlagen."
  ln -sf "$VHOST_PATH" "$VHOST_LINK"
  if [ "$REMOVE_DEFAULT" -eq 1 ]; then
    rm -f /etc/nginx/sites-enabled/default || true
  fi

  if [ -n "$MIGRATION_SOURCE_LINK" ] && [ "$MIGRATION_SOURCE_LINK" != "$VHOST_LINK" ]; then
    rm -f "$MIGRATION_SOURCE_LINK" || true
  fi

  nginx -t
  if [ -n "$MIGRATION_SOURCE_VHOST" ] && [ "$MIGRATION_SOURCE_VHOST" != "$VHOST_PATH" ] && [ -f "$MIGRATION_SOURCE_VHOST" ]; then
    mv -f "$MIGRATION_SOURCE_VHOST" "${MIGRATION_SOURCE_VHOST}.migrated.$(date +%Y%m%d%H%M%S)" || true
  fi
  reload_nginx_service
}

reload_nginx_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx
    systemctl reload nginx || systemctl restart nginx
    return
  fi

  if command -v service >/dev/null 2>&1; then
    service nginx reload || service nginx restart
    return
  fi

  nginx -s reload || warn "NGINX config installed, but automatic reload failed."
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
Provisioning Server – Installation Complete (HTTP)
============================================================
Mode:      $([ "$IS_UPGRADE" -eq 1 ] && echo "Upgrade/Refresh" || echo "Fresh install")
Instance:  $INSTANCE
Root:      $WEBROOT_ROOT
Webroot:   $WEBROOT_BASE
Default:   $WEBROOT_BASE/prov/tvip_provision.xml
Per-MAC:   $WEBROOT_BASE/prov.mac/<MAC>/tvip_provision.xml
Domain:    $DOMAIN
HTTP:      http://$DOMAIN:${HTTP_PORT}/
Config:    $VHOST_PATH
Logs:      /var/log/nginx/access.log, /var/log/nginx/error.log
EOF
}

rollback_notes() {
  [ -n "$BACKUP_PATH" ] || [ -n "$OLD_VHOST_BACKUP" ] || return 0
  cat <<EOF

Rollback notes:
Backup:    ${BACKUP_PATH:-none}
Old vhost: ${OLD_VHOST_BACKUP:-none}
EOF
}

main() {
  parse_args "$@"

  if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
  fi

  if [ "$LIST_INSTANCES" -eq 1 ]; then
    WEBROOT_ROOT="/var/www/${SERVICE_NAME}"
    print_instances
    exit 0
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    self_elevate "$@"
  fi

  resolve_paths
  select_existing_instance
  detect_existing_install
  detect_existing_domain
  choose_migration_name
  detect_existing_port

  if is_valid_fqdn "$DOMAIN"; then
    confirm_domain
  elif [ "$DRY_RUN" -eq 1 ]; then
    DOMAIN="<required>"
  else
    prompt_domain
    confirm_domain
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    dry_run_summary
    exit 0
  fi

  check_domain_conflict

  apt_install
  check_port
  create_migration_backup
  migrate_webroot
  prepare_dirs
  install_nginx_vhost
  configure_firewall
  summary
  rollback_notes
}

main "$@"
