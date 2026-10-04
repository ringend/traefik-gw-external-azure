#!/usr/bin/env bash
set -euo pipefail

# Start Traefik as a standalone Docker container (bridge networking).
# Requirements:
# - Docker daemon IPv6 enabled (daemon.json)
# - Cloudflare DNS API token in dns-key.file

if [[ -t 0 ]]; then
  echo ' Must be run via "sudo"'
  read -r -p " Press <Enter> to continue..... " _
else
  echo "Starting non-interactively under service control."
fi


CONTAINER_NAME="traefik-gateway-external"
TRAEFIK_IMAGE="traefik:v3.7.13@sha256:3429c14149401de2ac82fc72ddc6a92642332b90deb3012301ff211b9d2d0f18"
WAF_NETWORK_NAME="traefik-waf"
WAF_RETURN_NETWORK_NAME="wafreturn-external-ingress"
WAF_RETURN_NETWORK_SUBNET="172.19.0.0/16"
WAF_RETURN_NETWORK_IPV6_SUBNET="fd59:a22e:7327::/64"
WAF_RETURN_TRAEFIK_IPV4="172.19.0.10"
WAF_RETURN_TRAEFIK_IPV6="fd59:a22e:7327::10"

BASE_DIR="/nas-sync/traefik-gw-external-azure"
CONFIG_DIR="${BASE_DIR}/config"
CONFIG_BACKUP_DIR="${BASE_DIR}/config-backup"
ACME_HOST_DIR="/opt/docker-traefik-gateway-external"
ACME_FILE="${ACME_HOST_DIR}/acme.json"
ACME_SEED_FILE="${CONFIG_BACKUP_DIR}/acme.json"
ROUTES_FILE="${CONFIG_DIR}/routes.yml"
DNS_KEY_FILE="${CONFIG_DIR}/dns-key.file"
K8S_CA_FILE="${CONFIG_DIR}/k3s-ca.crt"
K8S_TOKEN_FILE="${CONFIG_DIR}/k3s-api-token.file"
K8S_KUBECONFIG_FILE="${CONFIG_DIR}/k3s-kubeconfig"

######################################################################
# Prerun checks

mkdir -p "${CONFIG_DIR}" "${CONFIG_BACKUP_DIR}"
if ! mkdir -p "${ACME_HOST_DIR}" 2>/dev/null; then
  echo "Cannot create ACME directory: ${ACME_HOST_DIR}" >&2
  echo "Create it with write access for $(id -un), then rerun." >&2
  exit 1
fi
if [ ! -f "${ACME_FILE}" ]; then
  if [ -f "${ACME_SEED_FILE}" ]; then
    if ! cp "${ACME_SEED_FILE}" "${ACME_FILE}" 2>/dev/null; then
      echo "Cannot seed ACME file from ${ACME_SEED_FILE}." >&2
      echo "Fix permissions on ${ACME_HOST_DIR} and rerun." >&2
      exit 1
    fi
  else
    if ! touch "${ACME_FILE}" 2>/dev/null; then
      echo "Cannot create ACME file: ${ACME_FILE}" >&2
      echo "Fix permissions on ${ACME_HOST_DIR} and rerun." >&2
      exit 1
    fi
  fi
fi
if [ ! -f "${ROUTES_FILE}" ]; then
  echo "Routes file not found: ${ROUTES_FILE}" >&2
  exit 1
fi
if [ ! -f "${K8S_CA_FILE}" ]; then
  echo "Kubernetes API CA file not found: ${K8S_CA_FILE}" >&2
  echo "Run /nas-sync/k3s/installation/scripts/install-external-traefik-api-access.sh first." >&2
  exit 1
fi
if [ ! -f "${K8S_TOKEN_FILE}" ]; then
  echo "Kubernetes API token file not found: ${K8S_TOKEN_FILE}" >&2
  echo "Run /nas-sync/k3s/installation/scripts/install-external-traefik-api-access.sh first." >&2
  exit 1
fi
if [ ! -f "${K8S_KUBECONFIG_FILE}" ]; then
  echo "Kubernetes kubeconfig file not found: ${K8S_KUBECONFIG_FILE}" >&2
  echo "Run /nas-sync/k3s/installation/scripts/install-external-traefik-api-access.sh first." >&2
  exit 1
fi

# Traefik requires restrictive permissions on ACME storage.
if ! chmod 600 "${ACME_FILE}" 2>/dev/null; then
  echo "Cannot set required permissions on ${ACME_FILE} (need 600)." >&2
  exit 1
fi
if [ ! -r "${K8S_CA_FILE}" ] || [ ! -r "${K8S_TOKEN_FILE}" ] || [ ! -r "${K8S_KUBECONFIG_FILE}" ]; then
  echo "Kubernetes API credential files are not readable." >&2
  exit 1
fi

# DNS API key file is required for ACME cert renewals.
if [ ! -f "${DNS_KEY_FILE}" ] || [ ! -r "${DNS_KEY_FILE}" ]; then
  echo "DNS key file missing or not readable: ${DNS_KEY_FILE}" >&2
  exit 1
fi

if ! docker network inspect "${WAF_NETWORK_NAME}" >/dev/null 2>&1; then
  echo "Creating private WAF network: ${WAF_NETWORK_NAME}"
  docker network create --driver bridge --ipv6 "${WAF_NETWORK_NAME}" >/dev/null
fi

if ! docker network inspect "${WAF_RETURN_NETWORK_NAME}" >/dev/null 2>&1; then
  echo "Creating private WAF return network: ${WAF_RETURN_NETWORK_NAME}"
  docker network create \
    --driver bridge \
    --ipv6 \
    --subnet "${WAF_RETURN_NETWORK_SUBNET}" \
    --gateway "172.19.0.1" \
    --subnet "${WAF_RETURN_NETWORK_IPV6_SUBNET}" \
    --gateway "fd59:a22e:7327::1" \
    "${WAF_RETURN_NETWORK_NAME}" >/dev/null
fi

waf_return_network_subnets="$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${WAF_RETURN_NETWORK_NAME}")"
if [[ "${waf_return_network_subnets}" != *"${WAF_RETURN_NETWORK_SUBNET}"* ]] || [[ "${waf_return_network_subnets}" != *"${WAF_RETURN_NETWORK_IPV6_SUBNET}"* ]]; then
  echo "Return network ${WAF_RETURN_NETWORK_NAME} does not use the required dedicated subnets." >&2
  exit 1
fi

######################################################################
# Stop and remove existing container (if present) so recreate is clean.
if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  IS_RUNNING="$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || echo false)"
  if [ "${IS_RUNNING}" = "true" ]; then
    echo "Stopping existing container: ${CONTAINER_NAME}"
    docker stop "${CONTAINER_NAME}" >/dev/null
  fi
  echo "Removing existing container: ${CONTAINER_NAME}"
  docker rm "${CONTAINER_NAME}" >/dev/null
fi

######################################################################
# Create container (bridge networking, CF token via file mount)
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network "${WAF_NETWORK_NAME}" \
  -p 80:80 \
  -p 443:443 \
  -e CF_DNS_API_TOKEN_FILE=/run/secrets/dns-key \
  -e KUBECONFIG=/etc/traefik/k3s-kubeconfig \
  -v "${CONFIG_DIR}/traefik.yml:/etc/traefik/traefik.yml:ro" \
  -v "${ROUTES_FILE}:/etc/traefik/routes.yml:ro" \
  -v "${DNS_KEY_FILE}:/run/secrets/dns-key:ro" \
  -v "${K8S_CA_FILE}:/etc/traefik/k3s-ca.crt:ro" \
  -v "${K8S_TOKEN_FILE}:/etc/traefik/k3s-api-token.file:ro" \
  -v "${K8S_KUBECONFIG_FILE}:/etc/traefik/k3s-kubeconfig:ro" \
  -v "${ACME_FILE}:/data/acme.json" \
  "${TRAEFIK_IMAGE}"

docker network connect \
  --ip "${WAF_RETURN_TRAEFIK_IPV4}" \
  --ip6 "${WAF_RETURN_TRAEFIK_IPV6}" \
  "${WAF_RETURN_NETWORK_NAME}" \
  "${CONTAINER_NAME}"

#######################################################################
# Verify container startup and health (if a HEALTHCHECK exists)
echo "Verifying container status..."
MAX_ATTEMPTS=12
SLEEP_SECONDS=4

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  RUNNING_STATE=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
  HEALTH_STATE=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

  if [[ "$RUNNING_STATE" != "true" ]]; then
    echo "Container is not running (attempt $attempt/$MAX_ATTEMPTS)."
  elif [[ "$HEALTH_STATE" == "healthy" || "$HEALTH_STATE" == "none" ]]; then
    echo "Container verification passed (running, health=$HEALTH_STATE)."
    exit 0
  else
    echo "Container is running but health=$HEALTH_STATE (attempt $attempt/$MAX_ATTEMPTS)."
  fi

  sleep "$SLEEP_SECONDS"
done

echo "Container failed startup verification."
echo "Last container logs:"
docker logs --tail 20 "$CONTAINER_NAME" || true
exit 1