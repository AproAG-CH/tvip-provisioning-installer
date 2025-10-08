#!/usr/bin/env bash
set -Eeuo pipefail


# TVIP Provisioning Server installer for Ubuntu 22.04 LTS (HTTP only)
# - Self-elevates to sudo if not run as root
# - Domain (FQDN) required; renders NGINX vhost + XML template with DOMAIN
# - Minimal vhost, HTTP only; optional custom port with conflict check
# - Idempotent: safe to re-run


HTTP_PORT=80
WEBROOT_BASE="/var/www/provisioning"
VHOST_PATH="/etc/nginx/sites-available/provisioning.conf"
VHOST_LINK="/etc/nginx/sites-enabled/provisioning.conf"
DOMAIN=""


log(){ echo "[+] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[x] $*" >&2; }
die(){ err "$1"; exit 1; }


self_elevate(){ if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi; }


parse_args(){
while [ $# -gt 0 ]; do
case "$1" in
-d|--domain) DOMAIN="$2"; shift 2 ;;
--http-port) HTTP_PORT="$2"; shift 2 ;;
--webroot) WEBROOT_BASE="$2"; shift 2 ;;
-y|--yes) export DEBIAN_FRONTEND=noninteractive; shift ;;
*) warn "Unknown option: $1"; shift ;;
esac
done
}


is_valid_fqdn(){ local d="$1"; [ -n "$d" ] || return 1; [[ "$d" =~ ^[^/]+$ ]] || return 1; [[ ! "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; [[ "$d" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]] || return 1; }


prompt_domain(){ while true; do read -rp "Domain (FQDN) für server_name: " DOMAIN || true; is_valid_fqdn "$DOMAIN" && break || echo "Ungültig. Bitte FQDN ohne http:// und ohne IP."; done; }


apt_install(){ log "Installing packages..."; apt-get update -y; apt-get install -y --no-install-recommends nginx curl ca-certificates acl; }


check_port(){
# prüft, ob Port frei ist (tcp LISTEN)
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ':(?:'"$HTTP_PORT"')$'; then
warn "Port $HTTP_PORT ist belegt."
read -rp "(E) Abbrechen oder (A)usweichport verwenden [E/a]: " ans
if [[ "${ans,,}" == "a" ]]; then
read -rp "Neuer HTTP-Port (z.B. 8080): " HTTP_PORT
else
die "Port $HTTP_PORT belegt – Installation abgebrochen."
fi
fi
}


prepare_dirs(){
log "Preparing webroot at $WEBROOT_BASE"
mkdir -p "$WEBROOT_BASE/html" "$WEBROOT_BASE/prov" "$WEBROOT_BASE/prov.mac"
chown -R www-data:www-data "$WEBROOT_BASE" || true
setfacl -Rm u:www-data:rx "$WEBROOT_BASE" 2>/dev/null || true


# Startseite
if [ ! -f "$WEBROOT_BASE/html/index.html" ]; then echo "TVIP Provisioning OK" > "$WEBROOT_BASE/html/index.html"; fi


# XML-Template rendern (Domain einsetzen), nur wenn nicht vorhanden
if [ ! -f "$WEBROOT_BASE/prov/tvip_provision.xml" ]; then
sed -e "s#{{DOMAIN}}#$DOMAIN#g" files/tvip_provision.xml > "$WEBROOT_BASE/prov/tvip_provision.xml"
chown www-data:www-data "$WEBROOT_BASE/prov/tvip_provision.xml" || true
chmod 0644 "$WEBROOT_BASE/prov/tvip_provision.xml" || true
fi
}


install_nginx_vhost(){
log "Installing NGINX vhost (minimal)"
main "$@"
