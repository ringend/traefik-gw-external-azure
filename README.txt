Traefik External Gateway Notes
==============================

Overview
--------
This project runs Traefik in Docker using:
- Static config: /nas-sync/traefik-gw-external-azure/config/traefik.yml
- Dynamic routes file: /nas-sync/traefik-gw-external-azure/config/routes.yml
- Kubernetes API CA file: /nas-sync/traefik-gw-external-azure/config/k3s-ca.crt
- Kubernetes API token file: /nas-sync/traefik-gw-external-azure/config/k3s-api-token.file
- Kubernetes kubeconfig file: /nas-sync/traefik-gw-external-azure/config/k3s-kubeconfig
- Cloudflare DNS API token file: /nas-sync/traefik-gw-external-azure/config/dns-key.file
- ACME seed file: /nas-sync/traefik-gw-external-azure/config-backup/acme.json
- ACME cert storage: /opt/docker-traefik-gateway-external/acme.json


How To Start
------------
Run from:
  /nas-sync/traefik-gw-external-azure

Command:
  ./docker-start.sh

The script:
- Recreates the traefik-gateway-external container
- Mounts config files from /nas-sync/traefik-gw-external-azure/config
- Uses the Kubernetes API providers for cluster `Ingress` and Traefik CRD resources with ingress class `external-traefik-azure`
- Seeds /opt/docker-traefik-gateway-external/acme.json from config-backup/acme.json on first run if the ACME file does not exist yet
- Stores and renews cert data in /opt/docker-traefik-gateway-external/acme.json after startup

Notes:
- This gateway starts blank. `config/routes.yml` contains no active routers or services.
- Kubernetes API access is enabled immediately through the mounted kubeconfig, CA, and token files.
- The gateway will only discover Kubernetes resources created for ingress class `external-traefik-azure`.
- The ACME seed lets this gateway start from the current certificate material, then renew independently using its own ACME file.


How To Set Docker Log Rotation
------------------------------
Run on the host as root:

  ./docker-set-log-config.sh

Defaults:
- max size per log file: 10m
- rotated log files kept: 5

Example with custom values:

  ./docker-set-log-config.sh --max-size 20m --max-file 7

Notes:
- The script merges the Docker daemon log settings into /etc/docker/daemon.json and restarts Docker by default.
- Existing containers keep their current log settings until they are recreated.
- Use `--no-restart` if you only want to write the config and restart Docker later.


Kubernetes API Access
---------------------
Before starting the gateway, place these files in /nas-sync/traefik-gw-external-azure/config:

- k3s-ca.crt
- k3s-api-token.file
- k3s-kubeconfig

The container uses `KUBECONFIG=/etc/traefik/k3s-kubeconfig` to access the k3s API.


Where The DNS API Key Is Stored
-------------------------------
File:
  /nas-sync/traefik-gw-external-azure/config/dns-key.file

Contents:
- Put only the Cloudflare API token on one line.
- No quotes, no extra text.


Where Certificates Are Stored
-----------------------------
Seed file:
  /nas-sync/traefik-gw-external-azure/config-backup/acme.json

Live file:
  /opt/docker-traefik-gateway-external/acme.json

Notes:
- On first run, the live ACME file is seeded from the backup file if present.
- After that, the external gateway renews certificates using its own live ACME file.
- Do not point this gateway at the internal gateway's live ACME file.


How To Add New Routes
---------------------
Option 1:
  Add file-based routes to /nas-sync/traefik-gw-external-azure/config/routes.yml

Option 2:
  Create Kubernetes `Ingress` or Traefik CRD resources that target ingress class `external-traefik-azure`


Current Route
-------------
- `monitor.ringen.cloud` -> proxies to `https://monitoring.ringen.cloud`
