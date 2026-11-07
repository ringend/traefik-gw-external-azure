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


NAS Origin Trust Boundary
-------------------------
The active routes file, rather than the historical route summary above, is
authoritative. NAS was activated for controlled production acceptance on
2026-11-02: both nas-waf-router and nas-health-waf-router now use
modsecurity-waf-service. The deny routers remain closed on noop@internal.

The HTTPS origin is nas-ext.ringen.cloud, using the existing cloudflare resolver
and *.ringen.cloud certificate. A NAS request must have BOTH:
- An immediate TCP peer in the current AzureFrontDoor.Backend service tag.
  nas-frontdoor-source deliberately has no X-Forwarded-For ipStrategy.
- X-Azure-FDID exactly 33338d0f-04c2-4699-8229-0e74374d4f34 (ai-rg/ai-fd-01).

NAS HTTP is denied; HTTPS requests with the public nas.ringen.cloud origin Host
or the wrong/missing FDID cannot reach the application. NAS guards reserve
9223372036854774807 (maximum 64-bit user router priority). Their rules are
disjoint and outrank generic health and Kubernetes-provider routes. Never assign
that reserved priority to a Kubernetes route, including a TCP passthrough route,
or create another external NAS route. Internal NAS routes must remain on
websecureint, never external-traefik-azure or an external entrypoint.

Before any activation, the coordinator must confirm standard Quantum, OIDC,
blocking WAF, internal canonical forwarded headers, and validated upstream TLS.
Then change ONLY the service of nas-waf-router and nas-health-waf-router to
modsecurity-waf-service. Host preservation is already enabled on that service;
there must be no direct k3s service shortcut. Roll back by restoring both
NAS services to noop@internal; retain all origin guards.

Front Door probe contract (Front Door and DNS are user-managed):
- HTTPS, origin Host AND TLS SNI nas-ext.ringen.cloud, certificate checks ON.
- HEAD /healthz (GET also supported), through the same source + FDID controls.
- nas-health-rewrite maps to /health before the blocking WAF and internal
  websecureint route; only a healthy app should return 200 after activation.
- No auth bypass on application paths. The unauthenticated /health response
  must be non-sensitive and must not redirect to OIDC or serve the SPA shell.
- Other hosts' /healthz probes remain gateway-only ping checks.
- When rolled back to staging, actual Front Door NAS requests return 418; untrusted direct
  origin requests return 403, even with a spoofed FDID and forwarded address.

Refresh the NAS source ranges at least weekly and before a planned deployment:
  powershell -File .\Update-NasFrontDoorRanges.ps1
This performs read-only Azure service-tag discovery, validates every prefix,
and replaces only the generated NAS allowlist. It does not change Azure.
Retain the previous list if lookup fails; review freshness operationally.

On EACH gateway, trigger and verify a dynamic reload after editing shared
NFS routes (NFS updates from another machine do not reliably trigger inotify):
  sudo touch /nas-sync/traefik-gw-external-azure/config/routes.yml
Wait at least 3 seconds, verify direct/spoofed NAS rejection, unchanged other-host
health, and real Front Door NAS health. Do not equate file presence with reload.
Use the existing systemd lifecycle only if a restart is actually needed.

No new NAS buffering or aggregate file-size limit is configured here.
The shared websecure readTimeout remains Traefik's 60s default; writeTimeout
is unlimited. Standard Quantum chunks must complete within that request-read
budget and the independently measured WAF/Front Door limits. Do not claim
large-transfer readiness without measuring authenticated chunks and downloads;
never solve an upload problem by disabling WAF inspection.
