# TVIP Provisioning Server – Ubuntu 22.04 (HTTP only, Domain erforderlich)

Minimal installer für einen TVIP-Provisioning-Webserver (NGINX) auf Ubuntu 22.04.

## Features
- HTTP only (für LAN/Closed Networks) – **Domain (FQDN) ist Pflicht**
- NGINX static hosting
- **MAC-basiertes Mapping** über HTTP-Header (Standard: `MAC-Address`)
- Canonical layout: `/var/www/provisioning/{prov,prov.mac}`
- Idempotent & self‑elevating (fragt bei Bedarf sudo an)

## Quick start
```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install.sh -o install.sh
sudo bash install.sh    # startet Wizard und fragt Domain (FQDN) ab
