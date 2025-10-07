TVIP Provisioning Server – Ubuntu 22.04 Installer (GitHub-ready)

This is a starter repo in one file you can paste to GitHub. It includes:

A production-friendly install.sh (idempotent) that sets up NGINX, folder structure prov/ and prov.mac/, self‑elevates to sudo when needed, and installs a ready-made server block with MAC-based rewrite logic (HTTP only).

A matching NGINX vhost file.

A minimal example tvip_provision.xml.

A README.md with usage and a one-liner installer (HTTP only, no TLS).

Replace all placeholder domains like provisioning.example.com with your actual hostname or IP.
## Quick start
```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install.sh -o install.sh
sudo bash install.sh    # startet Wizard und fragt Domain (FQDN) ab
