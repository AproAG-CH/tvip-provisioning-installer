TVIP Provisioning Server Installer
==================================

Installer and updater for a simple HTTP based TVIP provisioning server on Ubuntu.

The script can be used for a fresh install and can also be run again later with
the same command to refresh an existing installation.

New installations use `/var/www/tvip_provisioning_server` as the base folder.
Each provisioning server lives in its own subfolder such as `server1` or
`server2`. Additional servers can be installed on the same machine by using a
different `--instance` value and a different domain.

With the normal interactive command, the installer decides what to do:

- legacy installation found: upgrade it
- no installation found: create a new installation
- current installation found: ask whether to update it or add another instance
- multiple current installations found: ask which one to update
- older webroot found: ask whether to keep `provisioning` as the folder name or use the detected domain

## What it does

- installs required packages such as NGINX
- creates the provisioning webroot
- creates `prov/` for the default provisioning file
- creates `prov.mac/` for per-MAC provisioning files
- installs or refreshes the NGINX server block
- reloads NGINX after validating the config
- checks for duplicate NGINX `server_name` usage before writing
- creates a tar.gz backup before migrating an older webroot

Existing provisioning data is kept during upgrades. The installer does not
overwrite an existing valid `tvip_provision.xml` unless `--force-xml` is used.
Existing per-MAC folders under `prov.mac/` are also left untouched.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install.sh -o install.sh
sudo bash install.sh
```

Run the same command again later to upgrade or refresh the installation.
If a current installation already exists, the wizard asks whether another
provisioning server should be added.

For non-interactive usage:

```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install.sh -o install.sh
sudo bash install.sh --yes --domain provisioning.example.com
```

Install a second provisioning server on the same host:

```bash
sudo bash install.sh --yes --instance server2 --domain hotel-b.example.com
```

The instance can also be the domain name:

```bash
sudo bash install.sh --yes --instance hotel-b.example.com --domain hotel-b.example.com
```

## Options

- `--instance <name>`: server folder under `/var/www/tvip_provisioning_server`; allowed characters are letters, numbers, `.`, `_` and `-`
- `--domain <fqdn>`: domain used for NGINX `server_name` and default XML
- `--http-port <port>`: HTTP port, default `80`
- `--webroot <path>`: explicit provisioning root for advanced/custom installs
- `--force-xml`: replace the default `prov/tvip_provision.xml`
- `--remove-default-site`: remove the default NGINX site symlink during upgrades
- `--dry-run`: show planned actions without changing the system
- `--list-instances`: list existing provisioning server instances
- `--help`: show usage
- `--yes`: run without confirmation prompts where possible

Useful checks:

```bash
sudo bash install.sh --dry-run --domain provisioning.example.com
sudo bash install.sh --list-instances
sudo bash install.sh --help
```

Default paths for a new installation:

```text
/var/www/tvip_provisioning_server/
└── server1/
    ├── html/
    │   └── index.html
    ├── prov/
    │   └── tvip_provision.xml
    └── prov.mac/
```

With additional servers:

```text
/var/www/tvip_provisioning_server/
├── server1/
│   ├── html/
│   ├── prov/
│   │   └── tvip_provision.xml
│   └── prov.mac/
└── server2/
    ├── html/
    ├── prov/
    │   └── tvip_provision.xml
    └── prov.mac/
```

NGINX config:

```text
/etc/nginx/sites-available/tvip_provisioning_server.conf
/etc/nginx/sites-enabled/tvip_provisioning_server.conf
/etc/nginx/sites-available/tvip_provisioning_server_server2.conf
/etc/nginx/sites-enabled/tvip_provisioning_server_server2.conf
```

When the full repository is present, the installer reads templates from
`files/`. When `install.sh` is used as a standalone one-file installer, it falls
back to the embedded templates.

## Upgrade Behavior

When an existing installation is detected, the installer switches to
upgrade/refresh mode:

- migrates older webroots into `/var/www/tvip_provisioning_server/<name>`
- offers `provisioning` and the detected domain as migration folder names
- keeps current `server1`, `server2`, ... webroots in place
- keeps the existing default XML if it is valid XML
- keeps all `prov.mac/<MAC>/` folders
- detects the previous domain from the NGINX config or XML when no domain is passed
- detects the previous HTTP port from the NGINX config when no port is passed
- backs up the previous NGINX config before changing it
- creates migration backups under `/var/backups/tvip_provisioning_server`
- migrates the old enabled NGINX site from `provisioning.conf` to the new
  instance-specific config without deleting custom default sites
- reloads NGINX via `systemctl`, `service`, or `nginx -s reload` depending on
  what the system supports

If the existing default XML is missing or clearly invalid, the installer writes a
new default file and keeps a timestamped backup when possible.
